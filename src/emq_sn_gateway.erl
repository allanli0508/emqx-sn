%%%-------------------------------------------------------------------
%%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%-------------------------------------------------------------------

-module(emq_sn_gateway).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_fsm).

-include("emq_sn.hrl").

-include_lib("emqttd/include/emqttd.hrl").
-include_lib("emqttd/include/emqttd_protocol.hrl").


%% API.
-export([start_link/3]).

%% SUB/UNSUB Asynchronously. Called by plugins.
-export([subscribe/2, unsubscribe/2]).


-export([idle/2,                idle/3,
         wait_for_will_topic/2, wait_for_will_topic/3,
         wait_for_will_msg/2,   wait_for_will_msg/3,
         connected/2,           connected/3,
         asleep/2,              asleep/3,
         awake/2,               awake/3]).

-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

-record(connection, {socket, peer}).

-record(will,  {will_retain = false         :: boolean(),
                will_qos    = ?QOS_0        :: mqtt_qos(),
                will_topic  = undefined     :: undefined | binary(),
                will_msg    = undefined     :: undefined | binary()}).


-record(state, {gwid                        :: integer(),
                conn                        :: term(),
                protocol                    :: term(),
                client_id                   :: binary(),
                will                        :: term(),
                keepalive_duration          :: integer(),
                keepalive                   :: undefined | tuple(),
                connpkt                     :: term(),
                awaiting_suback = []        :: list(),
                idle_timer = undefined      :: term(),
                asleep_timer                :: tuple(),
                asleep_msg_queue            :: term()}).

-define(LOG(Level, Format, Args, State),
            lager:Level("MQTT-SN(~s): " ++ Format,
                        [esockd_net:format(State#state.conn#connection.peer) | Args])).
-define(LOG2(Level, Format, Args, Peer),
            lager:Level("MQTT-SN(~s): " ++ Format,
                        [esockd_net:format(Peer) | Args])).
-define(APP, emq_sn).


-ifdef(TEST).
-define(PROTO_INIT(A, B, C),            test_mqtt_broker:proto_init(A, B, C)).
-define(PROTO_RECEIVE(A, B),            test_mqtt_broker:proto_receive(A, B)).
-define(PROTO_SHUTDOWN(A, B),           ok).
-else.
-define(PROTO_INIT(A, B, C),            emqttd_protocol:init(A, B, C)).
-define(PROTO_RECEIVE(A, B),            emqttd_protocol:received(A, B)).
-define(PROTO_SHUTDOWN(A, B),           emqttd_protocol:shutdown(A, B)).
-endif.


%%--------------------------------------------------------------------
%% Exported APIs
%%--------------------------------------------------------------------

-spec(start_link(inet:socket(), {inet:ip_address(), inet:port()}, integer()) -> {ok, pid()}).
start_link(Sock, Peer, GwId) ->
    gen_fsm:start_link(?MODULE, [Sock, Peer, GwId], []).


subscribe(GwPid, TopicTable) ->
    gen_fsm:send_event(GwPid, {subscribe, TopicTable}).

unsubscribe(GwPid, Topics) ->
    gen_fsm:send_event(GwPid, {unsubscribe, Topics}).




%%--------------------------------------------------------------------
%% gen_fsm Callbacks
%%--------------------------------------------------------------------


init([Sock, Peer, GwId]) ->
    Conn = #connection{socket = Sock, peer = Peer},
    SendFun = fun(Packet) -> send_message(transform(Packet, fun(MsgId) -> dequeue_puback_msgid(MsgId) end ), Conn) end,
    PktOpts = [{max_clientid_len, 24}, {max_packet_size, 256}],
    ProtoState = ?PROTO_INIT(Peer, SendFun, PktOpts),
    State = #state{gwid = GwId,
                   conn = Conn,
                   protocol = ProtoState,
                   asleep_timer = emq_sn_asleep_timer:init(),
                   asleep_msg_queue = queue:new()},
    {ok, idle, State, 3000}.


idle(?SN_SEARCHGW_MSG(_Radius), StateData = #state{idle_timer = Timer, gwid = GwId, conn = Conn}) ->
    send_message(?SN_GWINFO_MSG(GwId, <<>>), Conn),
    NewTimer =  case Timer of
                    undefined -> start_idle_timer();
                    _Other    -> Timer   % do not start a new timer if one already exist
                end,
    {next_state, idle, StateData#state{idle_timer = NewTimer}};


idle(?SN_CONNECT_MSG(Flags, _ProtoId, Duration, ClientId), StateData = #state{protocol = Proto}) ->
    Username = application:get_env(?APP, username, undefined),
    Password = application:get_env(?APP, password, undefined),
    #mqtt_sn_flags{will = Will, clean_session = CleanSession} = Flags,
    ConnPkt = #mqtt_packet_connect{client_id  = ClientId,
                                   clean_sess = CleanSession,
                                   username = Username,
                                   password = Password,
                                   keep_alive = Duration},
    case Will of
        true  ->
            send_message(?SN_WILLTOPICREQ_MSG(), StateData#state.conn),
            {next_state, wait_for_will_topic, StateData#state{connpkt = ConnPkt, client_id = ClientId, keepalive_duration = Duration}};
        false ->
            case ?PROTO_RECEIVE(?CONNECT_PACKET(ConnPkt), Proto) of
                {ok, Proto1}           -> next_state(connected, StateData#state{client_id = ClientId, protocol = Proto1, keepalive_duration = Duration});
                {error, Error}         -> shutdown(Error, StateData);
                {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
                {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
            end
    end;

idle(?SN_ADVERTISE_MSG(_GwId, _Radius), StateData) ->
    % ignore
    {next_state, idle, StateData};

idle(?SN_DISCONNECT_MSG(_Duration), StateData) ->
    % ignore
    {next_state, idle, StateData};

idle(Event, StateData) ->
    ?LOG(error, "idle UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, idle, StateData}.

wait_for_will_topic(?SN_WILLTOPIC_EMPTY_MSG, StateData=#state{connpkt = ConnPkt, protocol = Proto}) ->
    % empty willtopic means deleting will
    case ?PROTO_RECEIVE(?CONNECT_PACKET(ConnPkt), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1, will = undefined});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end;

wait_for_will_topic(?SN_WILLTOPIC_MSG(Flags, Topic), StateData=#state{conn = Conn}) ->
    #mqtt_sn_flags{qos = Qos, retain = Retain} = Flags,
    Will = #will{will_retain = Retain,
                 will_qos    = Qos,
                 will_topic  = Topic},
    send_message(?SN_WILLMSGREQ_MSG(), Conn),
    {next_state, wait_for_will_msg, StateData#state{will = Will}};

wait_for_will_topic(?SN_ADVERTISE_MSG(_GwId, _Radius), StateData) ->
    % ignore
    {next_state, wait_for_will_topic, StateData};

wait_for_will_topic(Event, StateData) ->
    ?LOG(error, "wait_for_will_topic UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, wait_for_will_topic, StateData}.

wait_for_will_msg(?SN_WILLMSG_MSG(Msg), StateData = #state{protocol = Proto, will = Will, connpkt = ConnPkt}) ->
    WillNew = Will#will{will_msg = Msg},
    case ?PROTO_RECEIVE(?CONNECT_PACKET(ConnPkt), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1, will = WillNew});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end;

wait_for_will_msg(?SN_ADVERTISE_MSG(_GwId, _Radius), StateData) ->
    % ignore
    {next_state, wait_for_will_msg, StateData};

wait_for_will_msg(Event, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, wait_for_will_msg, StateData}.

connected(?SN_REGISTER_MSG(_TopicId, MsgId, TopicName), StateData = #state{client_id = ClientId, conn = Conn}) ->
    case emq_sn_registry:register_topic(ClientId, TopicName) of
        undefined ->
            ?LOG(error, "TopicId is full! ClientId=~p, TopicName=~p", [ClientId, TopicName], StateData),
            send_message(?SN_REGACK_MSG(?SN_INVALID_TOPIC_ID, MsgId, ?SN_RC_NOT_SUPPORTED), Conn);
        wildcard_topic ->
            ?LOG(error, "wildcard topic can not be registered! ClientId=~p, TopicName=~p", [ClientId, TopicName], StateData),
            send_message(?SN_REGACK_MSG(?SN_INVALID_TOPIC_ID, MsgId, ?SN_RC_NOT_SUPPORTED), Conn);
        NewTopicId ->
            ?LOG(debug, "register ClientId=~p, TopicName=~p, NewTopicId=~p", [ClientId, TopicName, NewTopicId], StateData),
            send_message(?SN_REGACK_MSG(NewTopicId, MsgId, ?SN_RC_ACCECPTED), Conn)
    end,
    {next_state, connected, StateData};

connected(?SN_PUBLISH_MSG(Flags, TopicId, MsgId, Data), StateData) ->
    #mqtt_sn_flags{topic_id_type = TopicIdType} = Flags,
    do_publish(TopicIdType, TopicId, Data, Flags, MsgId, StateData);

connected(?SN_PUBACK_MSG(TopicId, MsgId, ReturnCode), StateData) ->
    do_puback(TopicId, MsgId, ReturnCode, connected, StateData);


connected(?SN_PUBREC_MSG(PubRec, MsgId), StateData)
    when PubRec == ?SN_PUBREC; PubRec == ?SN_PUBREL; PubRec == ?SN_PUBCOMP ->
    do_pubrec(PubRec, MsgId, StateData);

connected(?SN_SUBSCRIBE_MSG(Flags, MsgId, TopicId), StateData) ->
    #mqtt_sn_flags{qos = Qos, topic_id_type = TopicIdType} = Flags,
    do_subscribe(TopicIdType, TopicId, Qos, MsgId, StateData);

connected(?SN_UNSUBSCRIBE_MSG(Flags, MsgId, TopicId), StateData) ->
    #mqtt_sn_flags{topic_id_type = TopicIdType} = Flags,
    do_unsubscribe(TopicIdType, TopicId, MsgId, StateData);

connected(?SN_PINGREQ_MSG(_ClientId), StateData=#state{conn = Conn}) ->
    send_message(?SN_PINGRESP_MSG(), Conn),
    next_state(connected, StateData);

connected(?SN_REGACK_MSG(_TopicId, _MsgId, ?SN_RC_ACCECPTED), StateData) ->
    next_state(connected, StateData);
connected(?SN_REGACK_MSG(TopicId, MsgId, ReturnCode), StateData) ->
    ?LOG(error, "client does not accept register TopicId=~p, MsgId=~p, ReturnCode=~p", [TopicId, MsgId, ReturnCode], StateData),
    next_state(connected, StateData);

connected(?SN_DISCONNECT_MSG(Duration), StateData = #state{protocol = Proto, conn = Conn}) ->
    send_message(?SN_DISCONNECT_MSG(undefined), Conn),
    case Duration of
        undefined ->
            {stop, Reason, Proto1} = ?PROTO_RECEIVE(?PACKET(?DISCONNECT), Proto),
            stop(Reason, StateData#state{protocol = Proto1});
        Other     ->
            goto_asleep_state(StateData, Other)
    end;

connected(?SN_WILLTOPICUPD_MSG(Flags, Topic), StateData = #state{will = Will}) ->
    WillNew = case Topic of
        undefined -> undefined;
        _         -> update_will_topic(Will, Flags, Topic)
    end,
    send_message(?SN_WILLTOPICRESP_MSG(0), StateData#state.conn),
    {next_state, connected, StateData#state{will = WillNew}};

connected(?SN_WILLMSGUPD_MSG(Msg), StateData = #state{will = Will}) ->
    send_message(?SN_WILLMSGRESP_MSG(0), StateData#state.conn),
    {next_state, connected, StateData#state{will = update_will_msg(Will, Msg)}};

connected(?SN_ADVERTISE_MSG(_GwId, _Radius), StateData) ->
    % ignore
    {next_state, connected, StateData};

connected(Event, StateData) ->
    ?LOG(error, "connected UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, connected, StateData}.


asleep(?SN_DISCONNECT_MSG(Duration), StateData = #state{protocol = Proto}) ->
    send_message(?SN_DISCONNECT_MSG(undefined), StateData#state.conn),
    case Duration of
        undefined ->
            {stop, Reason, Proto1} = ?PROTO_RECEIVE(?PACKET(?DISCONNECT), Proto),
            stop(Reason, StateData#state{protocol = Proto1});
        Other     ->
            goto_asleep_state(StateData, Other)
    end;

asleep(?SN_PINGREQ_MSG(undefined), StateData) ->
    % ClientId in PINGREQ is mandatory
    {next_state, asleep, StateData};
asleep(?SN_PINGREQ_MSG(ClientIdPing), StateData = #state{client_id = ClientId}) ->
    case ClientIdPing of
        ClientId ->
            self() ! do_awake_jobs,
            % it is better to go awake state, since the jobs in awake may take long time
            % and asleep timer get timeout, it will cause disaster
            {next_state, awake, StateData};
        _Other   ->
            {next_state, asleep, StateData}
    end;

asleep(?SN_PUBACK_MSG(TopicId, MsgId, ReturnCode), StateData) ->
    do_puback(TopicId, MsgId, ReturnCode, asleep, StateData);


asleep(?SN_PUBREC_MSG(PubRec, MsgId), StateData) when PubRec == ?SN_PUBREC; PubRec == ?SN_PUBREL; PubRec == ?SN_PUBCOMP ->
    do_pubrec(PubRec, MsgId, StateData);

asleep(?SN_CONNECT_MSG(_Flags, _ProtoId, _Duration, _ClientId), StateData = #state{keepalive_duration = Interval, conn = Conn}) ->
    % device wakeup and goto connected state
    % keepalive timer may timeout in asleep state and delete itself, need to restart keepalive
    self() ! {keepalive, start, Interval},
    send_connack(Conn),
    next_state(connected, StateData);

asleep(Event, StateData) ->
    ?LOG(error, "asleep UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, asleep, StateData}.

awake(?SN_REGACK_MSG(_TopicId, _MsgId, ?SN_RC_ACCECPTED), StateData) ->
    next_state(awake, StateData);
awake(?SN_REGACK_MSG(TopicId, MsgId, ReturnCode), StateData) ->
    ?LOG(error, "client does not accept register TopicId=~p, MsgId=~p, ReturnCode=~p", [TopicId, MsgId, ReturnCode], StateData),
    next_state(awake, StateData);

awake(Event, StateData) ->
    ?LOG(error, "asleep UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, awake, StateData}.

idle(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, idle, StateData}.

wait_for_will_topic(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, wait_for_will_topic, StateData}.

wait_for_will_msg(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, wait_for_will_msg, StateData}.

connected(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, connected, StateData}.

asleep(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, asleep, StateData}.

awake(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, awake, StateData}.


handle_event(Event, StateName, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, StateName, StateData}.

handle_sync_event(Event, _From, StateName, StateData) ->
    ?LOG(error, "UNEXPECTED SYNC Event: ~p", [Event], StateData),
    {reply, ignored, StateName, StateData}.

handle_info({datagram, _From, Data}, StateName, StateData) ->
    case catch emq_sn_message:parse(Data) of
        {ok, Msg} ->
            ?LOG(info, "RECV ~p at state ~p", [emq_sn_message:format(Msg), StateName], StateData),
            ?MODULE:StateName(Msg, StateData); %% cool?
        {'EXIT',{format_error,_Stack}} ->
            next_state(StateName, StateData)
    end;

handle_info({deliver, Msg}, asleep, StateData = #state{asleep_msg_queue = AsleepMsgQue}) ->
    % section 6.14, Support of sleeping clients
    ?LOG(debug, "enqueue downlink message in asleep state Msg=~p", [Msg], StateData),
    NewAsleepMsgQue = queue:in(Msg, AsleepMsgQue),
    next_state(asleep, StateData#state{asleep_msg_queue = NewAsleepMsgQue});
handle_info({deliver, Msg}, StateName, StateData = #state{client_id = ClientId}) ->
    publish_message_to_device(Msg, ClientId, StateData#state.conn),
    next_state(StateName, StateData);

handle_info({redeliver, {?PUBREL, MsgId}}, StateName, StateData) ->
    send_message(?SN_PUBREC_MSG(?SN_PUBREL, MsgId), StateData#state.conn),
    next_state(StateName, StateData);

handle_info({keepalive, start, Interval}, StateName, StateData = #state{conn = Conn, keepalive = undefined}) ->
    ?LOG(debug, "Keepalive at the interval of ~p seconds", [Interval], StateData),
    StatFun =   fun() ->
                    case inet:getstat(Conn#connection.socket, [recv_oct]) of
                        {ok, [{recv_oct, RecvOct}]} -> {ok, RecvOct};
                        {error, Error}              -> {error, Error}
                    end
                end,
    case emqttd_keepalive:start(StatFun, Interval, {keepalive, check}) of
        {ok, KeepAlive} ->
            next_state(StateName, StateData#state{keepalive = KeepAlive});
        {error, Error} ->
            ?LOG(warning, "Keepalive error - ~p", [Error], StateData),
            shutdown(Error, StateData)
    end;

handle_info(do_awake_jobs, StateName, StateData=#state{conn = Conn, client_id = ClientId, asleep_msg_queue = AsleepMsgQue}) ->
    process_awake_jobs(AsleepMsgQue, ClientId, Conn),
    case StateName of
        awake -> goto_asleep_state(StateData, undefined);
        Other -> next_state(Other, StateData) % device send a CONNECT immediately before this do_awake_jobs is handled
    end;


handle_info({keepalive, start, _Interval}, StateName, StateData = #state{keepalive = _Available}) ->
    % keepalive is still running, do nothing
    next_state(StateName, StateData);


handle_info({keepalive, check}, StateName, StateData = #state{keepalive = KeepAlive}) ->
    case emqttd_keepalive:check(KeepAlive) of
        {ok, KeepAlive1} ->
            ?LOG(debug, "Keepalive check ok StateName=~p, KeepAlive=~p", [StateName, KeepAlive], StateData),
            next_state(StateName, StateData#state{keepalive = KeepAlive1});
        {error, timeout} ->
            case StateName of
                asleep ->
                    % ignore keepalive timeout in asleep
                    ?LOG(debug, "Keepalive timeout, ignore it in asleep", [], StateData),
                    next_state(StateName, StateData#state{keepalive = undefined});
                Other ->
                    ?LOG(debug, "Keepalive timeout in ~p", [Other], StateData),
                    shutdown(keepalive_timeout, StateData)
            end;
        {error, Error}   ->
            ?LOG(warning, "Keepalive error - ~p", [Error], StateData),
            shutdown(Error, StateData)
    end;

%% Asynchronous SUBACK
handle_info({suback, MsgId, [GrantedQos]}, StateName, StateData=#state{awaiting_suback = Awaiting}) ->
    Flags = #mqtt_sn_flags{qos = GrantedQos},
    {MsgId, TopicId} = find_suback_topicid(MsgId, Awaiting),
    ?LOG(debug, "suback Awaiting=~p, MsgId=~p, TopicId=~p", [Awaiting, MsgId, TopicId], StateData),
    send_message(?SN_SUBACK_MSG(Flags, TopicId, MsgId, ?SN_RC_ACCECPTED), StateData#state.conn),
    next_state(StateName, StateData#state{awaiting_suback = lists:delete({MsgId, TopicId}, Awaiting)});

handle_info({'$gen_cast', {subscribe, Topics}}, StateName, StateData) ->
    ?LOG(debug, "ignore subscribe Topics=~p", [Topics], StateData),
    {next_state, StateName, StateData};


handle_info(idle_timeout, idle, StateData) ->
    ?LOG(debug, "idle_timeout and quit", [], StateData),
    % receive a SEARCHGW from a device, but no next action for a long time, terminate this process
    stop(idle_timeout, StateData);
handle_info(idle_timeout, StateName, StateData) ->
    {next_state, StateName, StateData};



handle_info({asleep_timeout, Ref}, StateName, StateData=#state{asleep_timer = AsleepTimer}) ->
    ?LOG(debug, "asleep_timeout at ~p", [StateName], StateData),
    case emq_sn_asleep_timer:timeout(AsleepTimer, StateName, Ref) of
        terminate_process         -> stop(asleep_timeout, StateData);
        {restart_timer, NewTimer} -> goto_asleep_state(StateData#state{asleep_timer = NewTimer}, undefined);
        {stop_timer, NewTimer}    -> {next_state, StateName, StateData#state{asleep_timer = NewTimer}}
    end;



handle_info(Info, StateName, StateData) ->
    ?LOG(error, "UNEXPECTED INFO: ~p", [Info], StateData),
    {next_state, StateName, StateData}.


terminate(Reason, _StateName, StateData = #state{client_id = ClientId, keepalive = KeepAlive, protocol = Proto}) ->
    case Reason of
        asleep_timeout                -> do_publish_will(StateData);
        {shutdown, keepalive_timeout} -> do_publish_will(StateData);
        _ -> ok
    end,
    emq_sn_registry:unregister_topic(ClientId),
    emqttd_keepalive:cancel(KeepAlive),
    case {Proto, Reason} of
        {undefined, _} ->
            ok;
        {_, {shutdown, Error}} ->
            ?PROTO_SHUTDOWN(Error, Proto);
        {_, Reason} ->
            ?PROTO_SHUTDOWN(Reason, Proto)
    end.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.



%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------



transform(?CONNACK_PACKET(0), _FuncMsgIdToTopicId) ->
    ?SN_CONNACK_MSG(0);

transform(?CONNACK_PACKET(_ReturnCode), _FuncMsgIdToTopicId) ->
    ?SN_CONNACK_MSG(?SN_RC_CONGESTION);

transform(?PUBACK_PACKET(?PUBACK, MsgId), FuncMsgIdToTopicId) ->
    TopicIdFinal =  case FuncMsgIdToTopicId(MsgId) of
                        undefined -> 0;
                        TopicId -> TopicId
                    end,
    ?SN_PUBACK_MSG(TopicIdFinal, MsgId, ?SN_RC_ACCECPTED);

transform(?PUBACK_PACKET(?PUBREC, MsgId), _FuncMsgIdToTopicId) ->
    ?SN_PUBREC_MSG(?SN_PUBREC, MsgId);

transform(?PUBACK_PACKET(?PUBREL, MsgId), _FuncMsgIdToTopicId) ->
    ?SN_PUBREC_MSG(?SN_PUBREL, MsgId);

transform(?PUBACK_PACKET(?PUBCOMP, MsgId), _FuncMsgIdToTopicId) ->
    ?SN_PUBREC_MSG(?SN_PUBCOMP, MsgId);

transform(?SUBACK_PACKET(_MsgId, _QosTable), _FuncMsgIdToTopicId)->
    % SUBACK is not sent in this way
    % please refer to handle_info({suback, MsgId, [GrantedQos]}, ...)
    error(false);

transform(?UNSUBACK_PACKET(MsgId), _FuncMsgIdToTopicId)->
    ?SN_UNSUBACK_MSG(MsgId).

send_publish(Dup, Qos, Retain, TopicIdType, TopicId, MsgId, Payload, Conn) ->
    MsgId1 = case Qos > 0 of
                 true  -> MsgId;
                 false -> 0
             end,
    Flags = #mqtt_sn_flags{dup = Dup, qos = Qos, retain = Retain, topic_id_type = TopicIdType},
    Data = ?SN_PUBLISH_MSG(Flags, TopicId, MsgId1, Payload),
    send_message(Data, Conn).

send_register(TopicName, TopicId, MsgId, Conn=#connection{}) ->
    Data = ?SN_REGISTER_MSG(TopicId, MsgId, TopicName),
    send_message(Data, Conn).

send_pingresp(Conn=#connection{}) ->
    Data = ?SN_PINGRESP_MSG(),
    send_message(Data, Conn).

send_connack(Conn=#connection{}) ->
    Data = ?SN_CONNACK_MSG(?SN_RC_ACCECPTED),
    send_message(Data, Conn).


send_message(Msg, #connection{socket = Sock, peer = Peer}) ->
    ?LOG2(debug, "SEND ~p~n", [emq_sn_message:format(Msg)], Peer),
    {Host, Port} = Peer,
    gen_udp:send(Sock, Host, Port, emq_sn_message:serialize(Msg)).

next_state(StateName, StateData) ->
    {next_state, StateName, StateData}.



goto_asleep_state(StateData=#state{asleep_timer = AsleepTimer}, Duration) ->
    ?LOG(debug, "goto_asleep_state Duration=~p", [Duration], StateData),
    NewTimer = emq_sn_asleep_timer:start(AsleepTimer, Duration),
    {next_state, asleep, StateData#state{asleep_timer = NewTimer}, hibernate}.


shutdown(Error, StateData) ->
    {stop, {shutdown, Error}, StateData}.

stop(Reason, StateData) ->
    {stop, Reason, StateData}.

mqttsn_to_mqtt(?SN_PUBACK)  -> ?PUBACK;
mqttsn_to_mqtt(?SN_PUBREC)  -> ?PUBREC;
mqttsn_to_mqtt(?SN_PUBREL)  -> ?PUBREL;
mqttsn_to_mqtt(?SN_PUBCOMP) -> ?PUBCOMP.



do_subscribe(?SN_NORMAL_TOPIC, TopicId, Qos, MsgId, StateData=#state{client_id = ClientId}) ->
    case emq_sn_registry:register_topic(ClientId, TopicId)of
        undefined ->
            send_message(?SN_SUBACK_MSG(#mqtt_sn_flags{qos = Qos}, ?SN_INVALID_TOPIC_ID, MsgId, ?SN_RC_INVALID_TOPIC_ID), StateData#state.conn),
            next_state(connected, StateData);
        wildcard_topic ->
            proto_subscribe(TopicId, Qos, MsgId, ?SN_INVALID_TOPIC_ID, StateData);
        NewTopicId ->
            proto_subscribe(TopicId, Qos, MsgId, NewTopicId, StateData)
    end;
do_subscribe(?SN_PREDEFINED_TOPIC, TopicId, Qos, MsgId, StateData=#state{client_id = ClientId}) ->
    case emq_sn_registry:lookup_topic(ClientId, TopicId) of
        undefined ->
            send_message(?SN_SUBACK_MSG(#mqtt_sn_flags{qos = Qos}, TopicId, MsgId, ?SN_RC_INVALID_TOPIC_ID), StateData#state.conn),
            next_state(connected, StateData);
        PredefinedTopic ->
            proto_subscribe(PredefinedTopic, Qos, MsgId, TopicId, StateData)
        end;
do_subscribe(?SN_SHORT_TOPIC, TopicId, Qos, MsgId, StateData) ->
    TopicName = case is_binary(TopicId) of
            true -> TopicId;
            false -> <<TopicId:16>>
        end,
    proto_subscribe(TopicName, Qos, MsgId, ?SN_INVALID_TOPIC_ID, StateData);
do_subscribe(_, _TopicId, Qos, MsgId, StateData) ->
    send_message(?SN_SUBACK_MSG(#mqtt_sn_flags{qos = Qos}, ?SN_INVALID_TOPIC_ID, MsgId, ?SN_RC_INVALID_TOPIC_ID), StateData#state.conn),
    next_state(connected, StateData).



do_unsubscribe(?SN_NORMAL_TOPIC, TopicId, MsgId, StateData) ->
    proto_unsubscribe(TopicId, MsgId, StateData);
do_unsubscribe(?SN_PREDEFINED_TOPIC, TopicId, MsgId, StateData=#state{client_id = ClientId}) ->
    case emq_sn_registry:lookup_topic(ClientId, TopicId) of
        undefined ->
            send_message(?SN_UNSUBACK_MSG(MsgId), StateData#state.conn),
            next_state(connected, StateData);
        PredefinedTopic ->
            proto_unsubscribe(PredefinedTopic, MsgId, StateData)
    end;
do_unsubscribe(?SN_SHORT_TOPIC, TopicId, MsgId, StateData) ->
    TopicName = case is_binary(TopicId) of
                    true  -> TopicId;
                    false -> <<TopicId:16>>
                end,
    proto_unsubscribe(TopicName, MsgId, StateData);
do_unsubscribe(_, _TopicId, MsgId, StateData) ->
    send_message(?SN_UNSUBACK_MSG(MsgId), StateData#state.conn),
    next_state(connected, StateData).

do_publish(?SN_NORMAL_TOPIC, TopicId, Data, Flags, MsgId, StateData) ->
    %% Handle normal topic id as predefined topic id, to be compatible with paho mqtt-sn library
    do_publish(?SN_PREDEFINED_TOPIC, TopicId, Data, Flags, MsgId, StateData);
do_publish(?SN_PREDEFINED_TOPIC, TopicId, Data, Flags, MsgId, StateData=#state{client_id = ClientId}) ->
    #mqtt_sn_flags{qos = Qos, dup = Dup, retain = Retain} = Flags,
    case emq_sn_registry:lookup_topic(ClientId, TopicId) of
        undefined ->
            (Qos =/= ?QOS0) andalso send_message(?SN_PUBACK_MSG(TopicId, MsgId, ?SN_RC_INVALID_TOPIC_ID), StateData#state.conn),
            next_state(connected, StateData);
        PredefinedTopic ->
            proto_publish(PredefinedTopic, Data, Dup, Qos, Retain, MsgId, TopicId, StateData)
    end;
do_publish(?SN_SHORT_TOPIC, TopicId, Data, Flags, MsgId, StateData) ->
    #mqtt_sn_flags{qos = Qos, dup = Dup, retain = Retain} = Flags,
    TopicName = <<TopicId:16>>,
    case emq_sn_registry:wildcard(TopicName) of
        true ->
            (Qos =/= ?QOS0) andalso send_message(?SN_PUBACK_MSG(TopicId, MsgId, ?SN_RC_NOT_SUPPORTED), StateData#state.conn),
            next_state(connected, StateData);
        false ->
            proto_publish(TopicName, Data, Dup, Qos, Retain, MsgId, TopicId, StateData)
    end;
do_publish(_, TopicId, _Data, #mqtt_sn_flags{qos = Qos}, MsgId, StateData) ->
    (Qos =/= ?QOS0) andalso send_message(?SN_PUBACK_MSG(TopicId, MsgId, ?SN_RC_NOT_SUPPORTED), StateData#state.conn),
    next_state(connected, StateData).

do_publish_will(#state{will = undefined}) ->
    ok;
do_publish_will(#state{will = #will{will_msg = undefined}}) ->
    ok;
do_publish_will(#state{will = #will{will_topic = undefined}}) ->
    ok;
do_publish_will(#state{will = Will, protocol = Proto}) ->
    #will{will_qos = Qos, will_retain = Retain, will_topic = Topic, will_msg = Payload } = Will,
    Publish = #mqtt_packet{header   = #mqtt_packet_header{type = ?PUBLISH, dup = false, qos = Qos, retain = Retain},
        variable = #mqtt_packet_publish{topic_name = Topic, packet_id = 1000},
        payload  = Payload},
    ?PROTO_RECEIVE(Publish, Proto),
    Qos =:= ?QOS2 andalso ?PROTO_RECEIVE(?PUBACK_PACKET(?PUBREL, 1000), Proto).


do_puback(TopicId, MsgId, ReturnCode, StateName, StateData=#state{client_id = ClientId, protocol = Proto}) ->
    case ReturnCode of
        ?SN_RC_ACCECPTED ->
            case ?PROTO_RECEIVE(?PUBACK_PACKET(?PUBACK, MsgId), Proto) of
                {ok, Proto1}           -> next_state(StateName, StateData#state{protocol = Proto1});
                {error, Error}         -> shutdown(Error, StateData);
                {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
                {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
            end;
        ?SN_RC_INVALID_TOPIC_ID ->
            case emq_sn_registry:lookup_topic(ClientId, TopicId) of
                undefined -> ok;
                TopicName ->
                    send_register(TopicName, TopicId, MsgId, StateData#state.conn),
                    next_state(StateName, StateData)
            end;
        _ ->
            ?LOG(error, "CAN NOT handle PUBACK ReturnCode=~p", [ReturnCode], StateData),
            next_state(StateName, StateData)
    end.


do_pubrec(PubRec, MsgId, StateData=#state{protocol = Proto}) ->
    case ?PROTO_RECEIVE(?PUBACK_PACKET(mqttsn_to_mqtt(PubRec), MsgId), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end.

proto_subscribe(TopicName, Qos, MsgId, TopicId, StateData=#state{protocol = Proto, awaiting_suback = Awaiting}) ->
    ?LOG(debug, "subscribe Topic=~p, MsgId=~p, TopicId=~p", [TopicName, MsgId, TopicId], StateData),
    NewAwaiting = lists:append(Awaiting, [{MsgId, TopicId}]),
    case ?PROTO_RECEIVE(?SUBSCRIBE_PACKET(MsgId, [{TopicName, Qos}]), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1, awaiting_suback = NewAwaiting});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end.


proto_unsubscribe(TopicName, MsgId, StateData=#state{protocol = Proto}) ->
    ?LOG(debug, "unsubscribe Topic=~p, MsgId=~p", [TopicName, MsgId], StateData),
    case ?PROTO_RECEIVE(?UNSUBSCRIBE_PACKET(MsgId, [TopicName]), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end.

proto_publish(TopicName, Data, Dup, Qos, Retain, MsgId, TopicId, StateData=#state{protocol = Proto}) ->
    (Qos =/= ?QOS0) andalso enqueue_puback_msgid(TopicId, MsgId),
    Publish = #mqtt_packet{header   = #mqtt_packet_header{type = ?PUBLISH, dup = Dup, qos = Qos, retain = Retain},
                            variable = #mqtt_packet_publish{topic_name = TopicName, packet_id = MsgId},
                            payload  = Data},
    case ?PROTO_RECEIVE(Publish, Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end.


find_suback_topicid(MsgId, []) ->
    {MsgId, 0};
find_suback_topicid(MsgId, [{MsgId, TopicId}|_Rest]) ->
    {MsgId, TopicId};
find_suback_topicid(MsgId, [{_, _}|Rest]) ->
    find_suback_topicid(MsgId, Rest).


publish_message_to_device(Msg, ClientId, Conn=#connection{}) ->
    #mqtt_packet{header   = #mqtt_packet_header{type = ?PUBLISH, dup = Dup, qos = Qos, retain = Retain},
        variable = #mqtt_packet_publish{topic_name = TopicName, packet_id = MsgId0},
        payload  = Payload} = emqttd_message:to_packet(Msg),
    MsgId = message_id(MsgId0),
    case emq_sn_registry:lookup_topic_id(ClientId, TopicName) of
        undefined ->
            case byte_size(TopicName) of
                2 ->
                    <<TransTopicId:16>> = TopicName,
                    send_publish(Dup, Qos, Retain, ?SN_SHORT_TOPIC, TransTopicId, MsgId, Payload, Conn);  % use short topic name
                _ ->
                    register_and_notify_client(TopicName, Payload, Dup, Qos, Retain, MsgId, ClientId, Conn)
            end;
        TopicId   ->
            send_publish(Dup, Qos, Retain, ?SN_PREDEFINED_TOPIC, TopicId, MsgId, Payload, Conn)   % use pre-defined topic id
    end.


publish_asleep_messages_to_device(AsleepMsg, ClientId, Conn, Qos2Count) ->
    case queue:is_empty(AsleepMsg) of
        false ->
            Msg = queue:get(AsleepMsg),
            publish_message_to_device(Msg, ClientId, Conn),
            NewCount = case is_qos2_msg(Msg) of
                           true -> Qos2Count + 1;
                           false -> Qos2Count
                       end,
            publish_asleep_messages_to_device(queue:drop(AsleepMsg), ClientId, Conn, NewCount);
        true ->
            Qos2Count
    end.


register_and_notify_client(TopicName, Payload, Dup, Qos, Retain, MsgId, ClientId, Conn) ->
    TopicId = emq_sn_registry:register_topic(ClientId, TopicName),
    ?LOG2(debug, "register TopicId=~p, TopicName=~p, Payload=~p, Dup=~p, Qos=~p, Retain=~p, MsgId=~p",
        [TopicId, TopicName, Payload, Dup, Qos, Retain, MsgId], Conn#connection.peer),
    send_register(TopicName, TopicId, MsgId, Conn),
    send_publish(Dup, Qos, Retain, ?SN_PREDEFINED_TOPIC, TopicId, MsgId, Payload, Conn).


message_id(undefined) ->
    rand:uniform(16#FFFF);
message_id(MsgId) ->
    MsgId.

update_will_topic(undefined, #mqtt_sn_flags{qos = Qos, retain = Retain}, Topic) ->
    #will{will_qos = Qos, will_retain = Retain, will_topic = Topic};
update_will_topic(Will=#will{}, #mqtt_sn_flags{qos = Qos, retain = Retain}, Topic) ->
    Will#will{will_qos = Qos, will_retain = Retain, will_topic = Topic}.

update_will_msg(undefined, Msg) ->
    #will{will_msg = Msg};
update_will_msg(Will=#will{}, Msg) ->
    Will#will{will_msg = Msg}.


start_idle_timer() ->
    erlang:send_after(timer:seconds(10), self(), idle_timeout).



process_awake_jobs(AsleepMsg, ClientId, Conn=#connection{}) ->
    publish_asleep_messages_to_device(AsleepMsg, ClientId, Conn, 0),
    %% TODO: what about publishing qos2 messages? wait more time for pubrec & pubcomp from device?
    %%       or ask device to go connected state?
    send_pingresp(Conn).



enqueue_puback_msgid(TopicId, MsgId) ->
    put({puback_msgid, MsgId}, TopicId).

dequeue_puback_msgid(MsgId) ->
    erase({puback_msgid, MsgId}).

is_qos2_msg(#mqtt_message{qos = 2})->
    true;
is_qos2_msg(#mqtt_message{})->
    false.


