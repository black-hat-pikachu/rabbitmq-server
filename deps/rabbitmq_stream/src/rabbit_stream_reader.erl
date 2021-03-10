%% The contents of this file are subject to the Mozilla Public License
%% Version 2.0 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/en-US/MPL/2.0/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is Pivotal Software, Inc.
%% Copyright (c) 2020-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_stream_reader).

-include_lib("rabbit_common/include/rabbit.hrl").

-include("rabbit_stream.hrl").

-type stream() :: binary().
-type publisher_id() :: byte().
-type publisher_reference() :: binary().
-type subscription_id() :: byte().

-record(publisher,
        {publisher_id :: publisher_id(),
         stream :: stream(),
         reference :: undefined | publisher_reference(),
         leader :: pid(),
         message_counters :: atomics:atomics_ref()}).
-record(consumer,
        {socket :: rabbit_net:socket(), %% ranch_transport:socket(),
         member_pid :: pid(),
         offset :: osiris:offset(),
         subscription_id :: subscription_id(),
         segment :: osiris_log:state(),
         credit :: integer(),
         stream :: stream(),
         counters :: atomics:atomics_ref()}).
-record(stream_connection_state,
        {data :: none | binary(), blocked :: boolean(),
         consumers :: #{subscription_id() => #consumer{}}}).
-record(stream_connection,
        {name :: binary(),
         %% server host
         host,
         %% client host
         peer_host,
         %% server port
         port,
         %% client port
         peer_port,
         auth_mechanism,
         connected_at :: integer(),
         helper_sup :: pid(),
         socket :: rabbit_net:socket(),
         publishers ::
             #{publisher_id() =>
                   #publisher{}}, %% FIXME replace with a list (0-255 lookup faster?)
         publisher_to_ids ::
             #{{stream(), publisher_reference()} => publisher_id()},
         stream_leaders :: #{stream() => pid()},
         stream_subscriptions :: #{stream() => [subscription_id()]},
         credits :: atomics:atomics_ref(),
         authentication_state :: atom(),
         user :: undefined | #user{},
         virtual_host :: undefined | binary(),
         connection_step ::
             atom(), % tcp_connected, peer_properties_exchanged, authenticating, authenticated, tuning, tuned, opened, failure, closing, closing_done
         frame_max :: integer(),
         heartbeat :: undefined | integer(),
         heartbeater :: any(),
         client_properties = #{} :: #{binary() => binary()},
         monitors = #{} :: #{reference() => stream()},
         stats_timer :: undefined | reference(),
         send_file_oct ::
             atomics:atomics_ref()}). % number of bytes sent with send_file (for metrics)
-record(configuration,
        {initial_credits :: integer(),
         credits_required_for_unblocking :: integer(),
         frame_max :: integer(),
         heartbeat :: integer()}).

-define(RESPONSE_FRAME_SIZE,
        10). % 2 (key) + 2 (version) + 4 (correlation ID) + 2 (response code)
-define(CREATION_EVENT_KEYS,
        [pid,
         name,
         port,
         peer_port,
         host,
         peer_host,
         ssl,
         peer_cert_subject,
         peer_cert_issuer,
         peer_cert_validity,
         auth_mechanism,
         ssl_protocol,
         ssl_key_exchange,
         ssl_cipher,
         ssl_hash,
         protocol,
         user,
         vhost,
         protocol,
         timeout,
         frame_max,
         channel_max,
         client_properties,
         connected_at,
         node,
         user_who_performed_action]).
-define(SIMPLE_METRICS, [pid, recv_oct, send_oct, reductions]).
-define(OTHER_METRICS,
        [recv_cnt,
         send_cnt,
         send_pend,
         state,
         channels,
         garbage_collection,
         timeout]).
-define(AUTH_NOTIFICATION_INFO_KEYS,
        [host,
         name,
         peer_host,
         peer_port,
         protocol,
         auth_mechanism,
         ssl,
         ssl_protocol,
         ssl_cipher,
         peer_cert_issuer,
         peer_cert_subject,
         peer_cert_validity]).

%% API
-export([start_link/4,
         init/1,
         info/2,
         consumers_info/2,
         publishers_info/2,
         in_vhost/2]).

start_link(KeepaliveSup, Transport, Ref, Opts) ->
    Pid = proc_lib:spawn_link(?MODULE, init,
                              [[KeepaliveSup, Transport, Ref, Opts]]),

    {ok, Pid}.

init([KeepaliveSup,
      Transport,
      Ref,
      #{initial_credits := InitialCredits,
        credits_required_for_unblocking := CreditsRequiredBeforeUnblocking,
        frame_max := FrameMax,
        heartbeat := Heartbeat}]) ->
    process_flag(trap_exit, true),
    {ok, Sock} =
        rabbit_networking:handshake(Ref,
                                    application:get_env(rabbitmq_stream,
                                                        proxy_protocol, false)),
    RealSocket = rabbit_net:unwrap_socket(Sock),
    case rabbit_net:connection_string(Sock, inbound) of
        {ok, ConnStr} ->
            Credits = atomics:new(1, [{signed, true}]),
            SendFileOct = atomics:new(1, [{signed, false}]),
            atomics:put(SendFileOct, 1, 0),
            init_credit(Credits, InitialCredits),
            {PeerHost, PeerPort, Host, Port} =
                socket_op(Sock,
                          fun(S) -> rabbit_net:socket_ends(S, inbound) end),
            Connection =
                #stream_connection{name =
                                       rabbit_data_coercion:to_binary(ConnStr),
                                   host = Host,
                                   peer_host = PeerHost,
                                   port = Port,
                                   peer_port = PeerPort,
                                   connected_at = os:system_time(milli_seconds),
                                   auth_mechanism = none,
                                   helper_sup = KeepaliveSup,
                                   socket = RealSocket,
                                   publishers = #{},
                                   publisher_to_ids = #{},
                                   stream_leaders = #{},
                                   stream_subscriptions = #{},
                                   credits = Credits,
                                   authentication_state = none,
                                   connection_step = tcp_connected,
                                   frame_max = FrameMax,
                                   send_file_oct = SendFileOct},
            State =
                #stream_connection_state{consumers = #{},
                                         blocked = false,
                                         data = none},
            Transport:setopts(RealSocket, [{active, once}]),

            listen_loop_pre_auth(Transport,
                                 Connection,
                                 State,
                                 #configuration{initial_credits =
                                                    InitialCredits,
                                                credits_required_for_unblocking
                                                    =
                                                    CreditsRequiredBeforeUnblocking,
                                                frame_max = FrameMax,
                                                heartbeat = Heartbeat});
        {Error, Reason} ->
            rabbit_net:fast_close(RealSocket),
            rabbit_log:warning("Closing connection because of ~p ~p~n",
                               [Error, Reason])
    end.

socket_op(Sock, Fun) ->
    RealSocket = rabbit_net:unwrap_socket(Sock),
    case Fun(Sock) of
        {ok, Res} ->
            Res;
        {error, Reason} ->
            rabbit_log:warning("Error during socket operation ~p~n", [Reason]),
            rabbit_net:fast_close(RealSocket),
            exit(normal)
    end.

init_credit(CreditReference, Credits) ->
    atomics:put(CreditReference, 1, Credits).

sub_credits(CreditReference, Credits) ->
    atomics:sub(CreditReference, 1, Credits).

add_credits(CreditReference, Credits) ->
    atomics:add(CreditReference, 1, Credits).

has_credits(CreditReference) ->
    atomics:get(CreditReference, 1) > 0.

has_enough_credits_to_unblock(CreditReference,
                              CreditsRequiredForUnblocking) ->
    atomics:get(CreditReference, 1) > CreditsRequiredForUnblocking.

increase_messages_consumed(Counters, Count) ->
    atomics:add(Counters, 1, Count).

set_consumer_offset(Counters, Offset) ->
    atomics:put(Counters, 2, Offset).

increase_messages_published(Counters, Count) ->
    atomics:add(Counters, 1, Count).

increase_messages_confirmed(Counters, Count) ->
    atomics:add(Counters, 2, Count).

increase_messages_errored(Counters, Count) ->
    atomics:add(Counters, 3, Count).

messages_consumed(Counters) ->
    atomics:get(Counters, 1).

consumer_offset(Counters) ->
    atomics:get(Counters, 2).

messages_published(Counters) ->
    atomics:get(Counters, 1).

messages_confirmed(Counters) ->
    atomics:get(Counters, 2).

messages_errored(Counters) ->
    atomics:get(Counters, 3).

listen_loop_pre_auth(Transport,
                     #stream_connection{socket = S} = Connection,
                     State,
                     #configuration{frame_max = FrameMax,
                                    heartbeat = Heartbeat} =
                         Configuration) ->
    {OK, Closed, Error} = Transport:messages(),
    %% FIXME introduce timeout to complete the connection opening (after block should be enough)
    receive
        {OK, S, Data} ->
            #stream_connection{connection_step = ConnectionStep0} = Connection,
            {Connection1, State1} =
                handle_inbound_data_pre_auth(Transport,
                                             Connection,
                                             State,
                                             Data),
            Transport:setopts(S, [{active, once}]),
            #stream_connection{connection_step = ConnectionStep} = Connection1,
            rabbit_log:info("Transitioned from ~p to ~p~n",
                            [ConnectionStep0, ConnectionStep]),
            case ConnectionStep of
                authenticated ->
                    TuneFrame =
                        <<?REQUEST:1,
                          ?COMMAND_TUNE:15,
                          ?VERSION_1:16,
                          FrameMax:32,
                          Heartbeat:32>>,
                    frame(Transport, Connection1, TuneFrame),
                    listen_loop_pre_auth(Transport,
                                         Connection1#stream_connection{connection_step
                                                                           =
                                                                           tuning},
                                         State1,
                                         Configuration);
                opened ->
                    % TODO remove registration to rabbit_stream_connections
                    % just meant to be able to close the connection remotely
                    % should be possible once the connections are available in ctl list_connections
                    pg_local:join(rabbit_stream_connections, self()),
                    Connection2 =
                        rabbit_event:init_stats_timer(Connection1,
                                                      #stream_connection.stats_timer),
                    Connection3 = ensure_stats_timer(Connection2),
                    Infos =
                        augment_infos_with_user_provided_connection_name(infos(?CREATION_EVENT_KEYS,
                                                                               Connection3,
                                                                               State1),
                                                                         Connection3),
                    rabbit_core_metrics:connection_created(self(), Infos),
                    rabbit_event:notify(connection_created, Infos),
                    rabbit_networking:register_non_amqp_connection(self()),
                    listen_loop_post_auth(Transport,
                                          Connection3,
                                          State1,
                                          Configuration);
                failure ->
                    close(Transport, S);
                _ ->
                    listen_loop_pre_auth(Transport,
                                         Connection1,
                                         State1,
                                         Configuration)
            end;
        {Closed, S} ->
            rabbit_log:info("Socket ~w closed [~w]~n", [S, self()]),
            ok;
        {Error, S, Reason} ->
            rabbit_log:info("Socket error ~p [~w]~n", [Reason, S, self()]);
        M ->
            rabbit_log:warning("Unknown message ~p~n", [M]),
            close(Transport, S)
    end.

augment_infos_with_user_provided_connection_name(Infos,
                                                 #stream_connection{client_properties
                                                                        =
                                                                        ClientProperties}) ->
    case ClientProperties of
        #{<<"connection_name">> := UserProvidedConnectionName} ->
            [{user_provided_name, UserProvidedConnectionName} | Infos];
        _ ->
            Infos
    end.

close(Transport, S) ->
    Transport:shutdown(S, write),
    Transport:close(S).

listen_loop_post_auth(Transport,
                      #stream_connection{socket = S,
                                         stream_subscriptions =
                                             StreamSubscriptions,
                                         credits = Credits,
                                         heartbeater = Heartbeater,
                                         monitors = Monitors,
                                         client_properties = ClientProperties,
                                         publishers = Publishers,
                                         publisher_to_ids = PublisherRefToIds,
                                         send_file_oct = SendFileOct} =
                          Connection0,
                      #stream_connection_state{consumers = Consumers,
                                               blocked = Blocked} =
                          State,
                      #configuration{credits_required_for_unblocking =
                                         CreditsRequiredForUnblocking} =
                          Configuration) ->
    Connection = ensure_stats_timer(Connection0),
    {OK, Closed, Error} = Transport:messages(),
    receive
        {OK, S, Data} ->
            {Connection1, State1} =
                handle_inbound_data_post_auth(Transport,
                                              Connection,
                                              State,
                                              Data),
            #stream_connection{connection_step = Step} = Connection1,
            case Step of
                closing ->
                    close(Transport, S),
                    rabbit_networking:unregister_non_amqp_connection(self()),
                    notify_connection_closed(Connection1, State1);
                close_sent ->
                    rabbit_log:debug("Transitioned to close_sent ~n"),
                    Transport:setopts(S, [{active, once}]),
                    listen_loop_post_close(Transport,
                                           Connection1,
                                           State1,
                                           Configuration);
                _ ->
                    State2 =
                        case Blocked of
                            true ->
                                case has_enough_credits_to_unblock(Credits,
                                                                   CreditsRequiredForUnblocking)
                                of
                                    true ->
                                        Transport:setopts(S, [{active, once}]),
                                        ok =
                                            rabbit_heartbeat:resume_monitor(Heartbeater),
                                        State1#stream_connection_state{blocked =
                                                                           false};
                                    false ->
                                        State1
                                end;
                            false ->
                                case has_credits(Credits) of
                                    true ->
                                        Transport:setopts(S, [{active, once}]),
                                        State1;
                                    false ->
                                        ok =
                                            rabbit_heartbeat:pause_monitor(Heartbeater),
                                        State1#stream_connection_state{blocked =
                                                                           true}
                                end
                        end,
                    listen_loop_post_auth(Transport,
                                          Connection1,
                                          State2,
                                          Configuration)
            end;
        {'DOWN', MonitorRef, process, _OsirisPid, _Reason} ->
            {Connection1, State1} =
                case Monitors of
                    #{MonitorRef := Stream} ->
                        Monitors1 = maps:remove(MonitorRef, Monitors),
                        C = Connection#stream_connection{monitors = Monitors1},
                        case
                            clean_state_after_stream_deletion_or_failure(Stream,
                                                                         C,
                                                                         State)
                        of
                            {cleaned, NewConnection, NewState} ->
                                StreamSize = byte_size(Stream),
                                FrameSize = 2 + 2 + 2 + 2 + StreamSize,
                                Transport:send(S,
                                               [<<FrameSize:32,
                                                  ?REQUEST:1,
                                                  ?COMMAND_METADATA_UPDATE:15,
                                                  ?VERSION_1:16,
                                                  ?RESPONSE_CODE_STREAM_NOT_AVAILABLE:16,
                                                  StreamSize:16,
                                                  Stream/binary>>]),
                                {NewConnection, NewState};
                            {not_cleaned, SameConnection, SameState} ->
                                {SameConnection, SameState}
                        end;
                    _ ->
                        {Connection, State}
                end,
            listen_loop_post_auth(Transport,
                                  Connection1,
                                  State1,
                                  Configuration);
        {'$gen_cast',
         {queue_event, _QueueResource,
          {osiris_written, _QueueResource, undefined, CorrelationList}}} ->
            {FirstPublisherId, _FirstPublishingId} =
                lists:nth(1, CorrelationList),
            {LastPublisherId, LastPublishingIds, LastCount} =
                lists:foldl(fun({PublisherId, PublishingId},
                                {CurrentPublisherId, PublishingIds, Count}) ->
                               case PublisherId of
                                   CurrentPublisherId ->
                                       {CurrentPublisherId,
                                        [PublishingIds, <<PublishingId:64>>],
                                        Count + 1};
                                   OtherPublisherId ->
                                       FrameSize = 2 + 2 + 1 + 4 + Count * 8,
                                       %% FIXME enforce max frame size
                                       %% in practice, this should be necessary only for very large chunks and for very small frame size limits
                                       Transport:send(S,
                                                      [<<FrameSize:32,
                                                         ?REQUEST:1,
                                                         ?COMMAND_PUBLISH_CONFIRM:15,
                                                         ?VERSION_1:16>>,
                                                       <<CurrentPublisherId:8>>,
                                                       <<Count:32>>,
                                                       PublishingIds]),
                                       #{CurrentPublisherId :=
                                             #publisher{message_counters =
                                                            Counters}} =
                                           Publishers,
                                       increase_messages_confirmed(Counters,
                                                                   Count),
                                       {OtherPublisherId, <<PublishingId:64>>,
                                        1}
                               end
                            end,
                            {FirstPublisherId, <<>>, 0}, CorrelationList),
            FrameSize = 2 + 2 + 1 + 4 + LastCount * 8,
            Transport:send(S,
                           [<<FrameSize:32,
                              ?REQUEST:1,
                              ?COMMAND_PUBLISH_CONFIRM:15,
                              ?VERSION_1:16>>,
                            <<LastPublisherId:8>>,
                            <<LastCount:32>>,
                            LastPublishingIds]),
            #{LastPublisherId := #publisher{message_counters = Counters}} =
                Publishers,
            increase_messages_confirmed(Counters, LastCount),
            CorrelationIdCount = length(CorrelationList),
            add_credits(Credits, CorrelationIdCount),
            State1 =
                case Blocked of
                    true ->
                        case has_enough_credits_to_unblock(Credits,
                                                           CreditsRequiredForUnblocking)
                        of
                            true ->
                                Transport:setopts(S, [{active, once}]),
                                ok =
                                    rabbit_heartbeat:resume_monitor(Heartbeater),
                                State#stream_connection_state{blocked = false};
                            false ->
                                State
                        end;
                    false ->
                        State
                end,
            listen_loop_post_auth(Transport, Connection, State1, Configuration);
        {'$gen_cast',
         {queue_event, _QueueResource,
          {osiris_written,
           #resource{name = Stream},
           PublisherReference,
           CorrelationList}}} ->
            %% FIXME handle case when publisher ID is not found (e.g. deleted before confirms arrive)
            PublisherId =
                maps:get({Stream, PublisherReference}, PublisherRefToIds,
                         undefined),
            PubIds =
                lists:foldl(fun(PublishingId, PublishingIds) ->
                               [PublishingIds, <<PublishingId:64>>]
                            end,
                            <<>>, CorrelationList),
            PublishingIdCount = length(CorrelationList),
            FrameSize = 2 + 2 + 1 + 4 + PublishingIdCount * 8,
            Transport:send(S,
                           [<<FrameSize:32,
                              ?REQUEST:1,
                              ?COMMAND_PUBLISH_CONFIRM:15,
                              ?VERSION_1:16>>,
                            <<PublisherId:8>>,
                            <<PublishingIdCount:32>>,
                            PubIds]),
            #{PublisherId := #publisher{message_counters = Counters}} =
                Publishers,
            increase_messages_confirmed(Counters, PublishingIdCount),
            add_credits(Credits, PublishingIdCount),
            State1 =
                case Blocked of
                    true ->
                        case has_enough_credits_to_unblock(Credits,
                                                           CreditsRequiredForUnblocking)
                        of
                            true ->
                                Transport:setopts(S, [{active, once}]),
                                ok =
                                    rabbit_heartbeat:resume_monitor(Heartbeater),
                                State#stream_connection_state{blocked = false};
                            false ->
                                State
                        end;
                    false ->
                        State
                end,
            listen_loop_post_auth(Transport, Connection, State1, Configuration);
        {'$gen_cast',
         {queue_event, #resource{name = StreamName},
          {osiris_offset, _QueueResource, -1}}} ->
            rabbit_log:info("received osiris offset event for ~p with offset "
                            "~p~n",
                            [StreamName, -1]),
            listen_loop_post_auth(Transport, Connection, State, Configuration);
        {'$gen_cast',
         {queue_event, #resource{name = StreamName},
          {osiris_offset, _QueueResource, Offset}}}
            when Offset > -1 ->
            {Connection1, State1} =
                case maps:get(StreamName, StreamSubscriptions, undefined) of
                    undefined ->
                        rabbit_log:info("osiris offset event for ~p, but no subscription "
                                        "(leftover messages after unsubscribe?)",
                                        [StreamName]),
                        {Connection, State};
                    [] ->
                        rabbit_log:info("osiris offset event for ~p, but no registered "
                                        "consumers!",
                                        [StreamName]),
                        {Connection#stream_connection{stream_subscriptions =
                                                          maps:remove(StreamName,
                                                                      StreamSubscriptions)},
                         State};
                    CorrelationIds when is_list(CorrelationIds) ->
                        Consumers1 =
                            lists:foldl(fun(CorrelationId, ConsumersAcc) ->
                                           #{CorrelationId := Consumer} =
                                               ConsumersAcc,
                                           #consumer{credit = Credit} =
                                               Consumer,
                                           Consumer1 =
                                               case Credit of
                                                   0 -> Consumer;
                                                   _ ->
                                                       {{segment, Segment1},
                                                        {credit, Credit1}} =
                                                           send_chunks(Transport,
                                                                       Consumer,
                                                                       SendFileOct),
                                                       Consumer#consumer{segment
                                                                             =
                                                                             Segment1,
                                                                         credit
                                                                             =
                                                                             Credit1}
                                               end,
                                           ConsumersAcc#{CorrelationId =>
                                                             Consumer1}
                                        end,
                                        Consumers, CorrelationIds),
                        {Connection,
                         State#stream_connection_state{consumers = Consumers1}}
                end,
            listen_loop_post_auth(Transport,
                                  Connection1,
                                  State1,
                                  Configuration);
        heartbeat_send ->
            Frame = <<?REQUEST:1, ?COMMAND_HEARTBEAT:15, ?VERSION_1:16>>,
            case catch frame(Transport, Connection, Frame) of
                ok ->
                    listen_loop_post_auth(Transport,
                                          Connection,
                                          State,
                                          Configuration);
                Unexpected ->
                    rabbit_log:info("Heartbeat send error ~p, closing connection~n",
                                    [Unexpected]),
                    C1 = demonitor_all_streams(Connection),
                    close(Transport, C1)
            end;
        heartbeat_timeout ->
            rabbit_log:info("Heartbeat timeout, closing connection~n"),
            C1 = demonitor_all_streams(Connection),
            close(Transport, C1);
        {infos, From} ->
            From ! {self(), ClientProperties},
            listen_loop_post_auth(Transport, Connection, State, Configuration);
        {'$gen_call', From, info} ->
            gen_server:reply(From, infos(?INFO_ITEMS, Connection, State)),
            listen_loop_post_auth(Transport, Connection, State, Configuration);
        {'$gen_call', From, {info, Items}} ->
            gen_server:reply(From, infos(Items, Connection, State)),
            listen_loop_post_auth(Transport, Connection, State, Configuration);
        {'$gen_call', From, {consumers_info, Items}} ->
            gen_server:reply(From, consumers_infos(Items, State)),
            listen_loop_post_auth(Transport, Connection, State, Configuration);
        {'$gen_call', From, {publishers_info, Items}} ->
            gen_server:reply(From, publishers_infos(Items, Connection)),
            listen_loop_post_auth(Transport, Connection, State, Configuration);
        emit_stats ->
            Connection1 = emit_stats(Connection, State),
            listen_loop_post_auth(Transport, Connection1, State, Configuration);
        {'$gen_cast', {force_event_refresh, Ref}} ->
            Infos =
                augment_infos_with_user_provided_connection_name(infos(?CREATION_EVENT_KEYS,
                                                                       Connection,
                                                                       State),
                                                                 Connection),
            rabbit_event:notify(connection_created, Infos, Ref),
            Connection1 =
                rabbit_event:init_stats_timer(Connection,
                                              #stream_connection.stats_timer),
            listen_loop_post_auth(Transport, Connection1, State, Configuration);
        {'$gen_call', From, {shutdown, Explanation}} ->
            % likely closing call from the management plugin
            gen_server:reply(From, ok),
            rabbit_log:info("Forcing stream connection ~p closing: ~p~n",
                            [self(), Explanation]),
            demonitor_all_streams(Connection),
            rabbit_networking:unregister_non_amqp_connection(self()),
            notify_connection_closed(Connection, State),
            close(Transport, S),
            ok;
        {Closed, S} ->
            demonitor_all_streams(Connection),
            rabbit_networking:unregister_non_amqp_connection(self()),
            notify_connection_closed(Connection, State),
            rabbit_log:info("Socket ~w closed [~w]~n", [S, self()]),
            ok;
        {Error, S, Reason} ->
            demonitor_all_streams(Connection),
            rabbit_networking:unregister_non_amqp_connection(self()),
            notify_connection_closed(Connection, State),
            rabbit_log:info("Socket error ~p [~w]~n", [Reason, S, self()]);
        M ->
            rabbit_log:warning("Unknown message ~p~n", [M]),
            %% FIXME send close
            listen_loop_post_auth(Transport, Connection, State, Configuration)
    end.

listen_loop_post_close(Transport,
                       #stream_connection{socket = S} = Connection,
                       State,
                       Configuration) ->
    {OK, Closed, Error} = Transport:messages(),
    %% FIXME demonitor streams
    %% FIXME introduce timeout to complete the connection closing (after block should be enough)
    receive
        {OK, S, Data} ->
            Transport:setopts(S, [{active, once}]),
            {Connection1, State1} =
                handle_inbound_data_post_close(Transport,
                                               Connection,
                                               State,
                                               Data),
            #stream_connection{connection_step = Step} = Connection1,
            case Step of
                closing_done ->
                    rabbit_log:debug("Received close confirmation from client"),
                    close(Transport, S),
                    rabbit_networking:unregister_non_amqp_connection(self()),
                    notify_connection_closed(Connection1, State1);
                _ ->
                    Transport:setopts(S, [{active, once}]),
                    listen_loop_post_close(Transport,
                                           Connection1,
                                           State1,
                                           Configuration)
            end;
        {Closed, S} ->
            rabbit_networking:unregister_non_amqp_connection(self()),
            notify_connection_closed(Connection, State),
            rabbit_log:info("Socket ~w closed [~w]~n", [S, self()]),
            ok;
        {Error, S, Reason} ->
            rabbit_log:info("Socket error ~p [~w]~n", [Reason, S, self()]),
            close(Transport, S),
            rabbit_networking:unregister_non_amqp_connection(self()),
            notify_connection_closed(Connection, State);
        M ->
            rabbit_log:warning("Ignored message on closing ~p~n", [M])
    end.

handle_inbound_data_pre_auth(Transport, Connection, State, Rest) ->
    handle_inbound_data(Transport,
                        Connection,
                        State,
                        Rest,
                        fun handle_frame_pre_auth/5).

handle_inbound_data_post_auth(Transport, Connection, State, Rest) ->
    handle_inbound_data(Transport,
                        Connection,
                        State,
                        Rest,
                        fun handle_frame_post_auth/5).

handle_inbound_data_post_close(Transport, Connection, State, Rest) ->
    handle_inbound_data(Transport,
                        Connection,
                        State,
                        Rest,
                        fun handle_frame_post_close/5).

handle_inbound_data(_Transport,
                    Connection,
                    State,
                    <<>>,
                    _HandleFrameFun) ->
    {Connection, State};
handle_inbound_data(Transport,
                    #stream_connection{frame_max = FrameMax} = Connection,
                    #stream_connection_state{data = none} = State,
                    <<Size:32, _Frame:Size/binary, _Rest/bits>>,
                    _HandleFrameFun)
    when FrameMax /= 0 andalso Size > FrameMax - 4 ->
    CloseReason = <<"frame too large">>,
    CloseReasonLength = byte_size(CloseReason),
    CloseFrame =
        <<?REQUEST:1,
          ?COMMAND_CLOSE:15,
          ?VERSION_1:16,
          1:32,
          ?RESPONSE_CODE_FRAME_TOO_LARGE:16,
          CloseReasonLength:16,
          CloseReason:CloseReasonLength/binary>>,
    frame(Transport, Connection, CloseFrame),
    {Connection#stream_connection{connection_step = close_sent}, State};
handle_inbound_data(Transport,
                    Connection,
                    #stream_connection_state{data = none} = State,
                    <<Size:32, Frame:Size/binary, Rest/bits>>,
                    HandleFrameFun) ->
    {Connection1, State1, Rest1} =
        HandleFrameFun(Transport, Connection, State, Frame, Rest),
    handle_inbound_data(Transport,
                        Connection1,
                        State1,
                        Rest1,
                        HandleFrameFun);
handle_inbound_data(_Transport,
                    Connection,
                    #stream_connection_state{data = none} = State,
                    Data,
                    _HandleFrameFun) ->
    {Connection, State#stream_connection_state{data = Data}};
handle_inbound_data(Transport,
                    Connection,
                    #stream_connection_state{data = Leftover} = State,
                    Data,
                    HandleFrameFun) ->
    State1 = State#stream_connection_state{data = none},
    %% FIXME avoid concatenation to avoid a new binary allocation
    %% see osiris_replica:parse_chunk/3
    handle_inbound_data(Transport,
                        Connection,
                        State1,
                        <<Leftover/binary, Data/binary>>,
                        HandleFrameFun).

generate_publishing_error_details(Acc, _Code, <<>>) ->
    Acc;
generate_publishing_error_details(Acc, Code,
                                  <<PublishingId:64,
                                    MessageSize:32,
                                    _Message:MessageSize/binary,
                                    Rest/binary>>) ->
    generate_publishing_error_details(<<Acc/binary, PublishingId:64,
                                        Code:16>>,
                                      Code, Rest).

handle_frame_pre_auth(Transport,
                      #stream_connection{socket = S} = Connection,
                      State,
                      <<?REQUEST:1,
                        ?COMMAND_PEER_PROPERTIES:15,
                        ?VERSION_1:16,
                        CorrelationId:32,
                        ClientPropertiesCount:32,
                        ClientPropertiesFrame/binary>>,
                      Rest) ->
    {ClientProperties, _} =
        rabbit_stream_utils:parse_map(ClientPropertiesFrame,
                                      ClientPropertiesCount),

    {ok, Product} = application:get_key(rabbit, description),
    {ok, Version} = application:get_key(rabbit, vsn),

    %% Get any configuration-specified server properties
    RawConfigServerProps =
        application:get_env(rabbit, server_properties, []),

    ConfigServerProperties =
        lists:foldl(fun({K, V}, Acc) ->
                       maps:put(
                           rabbit_data_coercion:to_binary(K), V, Acc)
                    end,
                    #{}, RawConfigServerProps),

    ServerProperties =
        maps:merge(ConfigServerProperties,
                   #{<<"product">> => Product,
                     <<"version">> => Version,
                     <<"cluster_name">> => rabbit_nodes:cluster_name(),
                     <<"platform">> => rabbit_misc:platform_and_version(),
                     <<"copyright">> => ?COPYRIGHT_MESSAGE,
                     <<"information">> => ?INFORMATION_MESSAGE}),

    ServerPropertiesCount = map_size(ServerProperties),

    ServerPropertiesFragment =
        maps:fold(fun(K, V, Acc) ->
                     Key = rabbit_data_coercion:to_binary(K),
                     Value = rabbit_data_coercion:to_binary(V),
                     KeySize = byte_size(Key),
                     ValueSize = byte_size(Value),
                     <<Acc/binary,
                       KeySize:16,
                       Key:KeySize/binary,
                       ValueSize:16,
                       Value:ValueSize/binary>>
                  end,
                  <<>>, ServerProperties),

    Frame =
        <<?RESPONSE:1,
          ?COMMAND_PEER_PROPERTIES:15,
          ?VERSION_1:16,
          CorrelationId:32,
          ?RESPONSE_CODE_OK:16,
          ServerPropertiesCount:32,
          ServerPropertiesFragment/binary>>,
    FrameSize = byte_size(Frame),

    Transport:send(S, [<<FrameSize:32>>, <<Frame/binary>>]),
    {Connection#stream_connection{client_properties = ClientProperties,
                                  authentication_state =
                                      peer_properties_exchanged},
     State, Rest};
handle_frame_pre_auth(Transport,
                      #stream_connection{socket = S} = Connection,
                      State,
                      <<?REQUEST:1,
                        ?COMMAND_SASL_HANDSHAKE:15,
                        ?VERSION_1:16,
                        CorrelationId:32>>,
                      Rest) ->
    Mechanisms = rabbit_stream_utils:auth_mechanisms(S),
    MechanismsFragment =
        lists:foldl(fun(M, Acc) ->
                       Size = byte_size(M),
                       <<Acc/binary, Size:16, M:Size/binary>>
                    end,
                    <<>>, Mechanisms),
    MechanismsCount = length(Mechanisms),
    Frame =
        <<?RESPONSE:1,
          ?COMMAND_SASL_HANDSHAKE:15,
          ?VERSION_1:16,
          CorrelationId:32,
          ?RESPONSE_CODE_OK:16,
          MechanismsCount:32,
          MechanismsFragment/binary>>,
    FrameSize = byte_size(Frame),

    Transport:send(S, [<<FrameSize:32>>, <<Frame/binary>>]),
    {Connection, State, Rest};
handle_frame_pre_auth(Transport,
                      #stream_connection{socket = S,
                                         authentication_state = AuthState0,
                                         host = Host} =
                          Connection0,
                      State,
                      <<?REQUEST:1,
                        ?COMMAND_SASL_AUTHENTICATE:15,
                        ?VERSION_1:16,
                        CorrelationId:32,
                        MechanismLength:16,
                        Mechanism:MechanismLength/binary,
                        SaslFragment/binary>>,
                      Rest) ->
    SaslBin =
        case SaslFragment of
            <<(-1):32/signed>> ->
                <<>>;
            <<SaslBinaryLength:32, SaslBinary:SaslBinaryLength/binary>> ->
                SaslBinary
        end,

    {Connection1, Rest1} =
        case rabbit_stream_utils:auth_mechanism_to_module(Mechanism, S) of
            {ok, AuthMechanism} ->
                AuthState =
                    case AuthState0 of
                        none ->
                            AuthMechanism:init(S);
                        AS ->
                            AS
                    end,
                RemoteAddress = list_to_binary(inet:ntoa(Host)),
                C1 = Connection0#stream_connection{auth_mechanism =
                                                       {Mechanism,
                                                        AuthMechanism}},
                {C2, FrameFragment} =
                    case AuthMechanism:handle_response(SaslBin, AuthState) of
                        {refused, Username, Msg, Args} ->
                            rabbit_core_metrics:auth_attempt_failed(RemoteAddress,
                                                                    Username,
                                                                    stream),
                            auth_fail(Username, Msg, Args, C1, State),
                            rabbit_log:warning(Msg, Args),
                            {C1#stream_connection{connection_step = failure},
                             <<?RESPONSE_AUTHENTICATION_FAILURE:16>>};
                        {protocol_error, Msg, Args} ->
                            rabbit_core_metrics:auth_attempt_failed(RemoteAddress,
                                                                    <<>>,
                                                                    stream),
                            notify_auth_result(none,
                                               user_authentication_failure,
                                               [{error,
                                                 rabbit_misc:format(Msg,
                                                                    Args)}],
                                               C1,
                                               State),
                            rabbit_log:warning(Msg, Args),
                            {C1#stream_connection{connection_step = failure},
                             <<?RESPONSE_SASL_ERROR:16>>};
                        {challenge, Challenge, AuthState1} ->
                            rabbit_core_metrics:auth_attempt_succeeded(RemoteAddress,
                                                                       <<>>,
                                                                       stream),
                            ChallengeSize = byte_size(Challenge),
                            {C1#stream_connection{authentication_state =
                                                      AuthState1,
                                                  connection_step =
                                                      authenticating},
                             <<?RESPONSE_SASL_CHALLENGE:16, ChallengeSize:32,
                               Challenge/binary>>};
                        {ok, User = #user{username = Username}} ->
                            case
                                rabbit_access_control:check_user_loopback(Username,
                                                                          S)
                            of
                                ok ->
                                    rabbit_core_metrics:auth_attempt_succeeded(RemoteAddress,
                                                                               Username,
                                                                               stream),
                                    notify_auth_result(Username,
                                                       user_authentication_success,
                                                       [],
                                                       C1,
                                                       State),
                                    {C1#stream_connection{authentication_state =
                                                              done,
                                                          user = User,
                                                          connection_step =
                                                              authenticated},
                                     <<?RESPONSE_CODE_OK:16>>};
                                not_allowed ->
                                    rabbit_core_metrics:auth_attempt_failed(RemoteAddress,
                                                                            Username,
                                                                            stream),
                                    rabbit_log:warning("User '~s' can only connect via localhost~n",
                                                       [Username]),
                                    {C1#stream_connection{connection_step =
                                                              failure},
                                     <<?RESPONSE_SASL_AUTHENTICATION_FAILURE_LOOPBACK:16>>}
                            end
                    end,
                Frame =
                    <<?RESPONSE:1,
                      ?COMMAND_SASL_AUTHENTICATE:15,
                      ?VERSION_1:16,
                      CorrelationId:32,
                      FrameFragment/binary>>,
                frame(Transport, C1, Frame),
                {C2, Rest};
            {error, _} ->
                Frame =
                    <<?RESPONSE:1,
                      ?COMMAND_SASL_AUTHENTICATE:15,
                      ?VERSION_1:16,
                      CorrelationId:32,
                      ?RESPONSE_SASL_MECHANISM_NOT_SUPPORTED:16>>,
                frame(Transport, Connection0, Frame),
                {Connection0#stream_connection{connection_step = failure}, Rest}
        end,

    {Connection1, State, Rest1};
handle_frame_pre_auth(_Transport,
                      #stream_connection{helper_sup = SupPid,
                                         socket = Sock,
                                         name = ConnectionName} =
                          Connection,
                      State,
                      <<?RESPONSE:1,
                        ?COMMAND_TUNE:15,
                        ?VERSION_1:16,
                        FrameMax:32,
                        Heartbeat:32>>,
                      Rest) ->
    rabbit_log:info("Tuning response ~p ~p ~n", [FrameMax, Heartbeat]),
    Parent = self(),
    %% sending a message to the main process so the heartbeat frame is sent from this main process
    %% otherwise heartbeat frames can interleave with chunk delivery
    %% (chunk delivery is made of 2 calls on the socket, one for the header and one send_file for the chunk,
    %% we don't want a heartbeat frame to sneak in in-between)
    SendFun =
        fun() ->
           Parent ! heartbeat_send,
           ok
        end,
    ReceiveFun = fun() -> Parent ! heartbeat_timeout end,
    Heartbeater =
        rabbit_heartbeat:start(SupPid,
                               Sock,
                               ConnectionName,
                               Heartbeat,
                               SendFun,
                               Heartbeat,
                               ReceiveFun),

    {Connection#stream_connection{connection_step = tuned,
                                  frame_max = FrameMax,
                                  heartbeat = Heartbeat,
                                  heartbeater = Heartbeater},
     State, Rest};
handle_frame_pre_auth(Transport,
                      #stream_connection{user = User, socket = S} = Connection,
                      State,
                      <<?REQUEST:1,
                        ?COMMAND_OPEN:15,
                        ?VERSION_1:16,
                        CorrelationId:32,
                        VirtualHostLength:16,
                        VirtualHost:VirtualHostLength/binary>>,
                      Rest) ->
    %% FIXME enforce connection limit (see rabbit_reader:is_over_connection_limit/2)
    {Connection1, Frame} =
        try
            rabbit_access_control:check_vhost_access(User,
                                                     VirtualHost,
                                                     {socket, S},
                                                     #{}),
            F = <<?RESPONSE:1,
                  ?COMMAND_OPEN:15,
                  ?VERSION_1:16,
                  CorrelationId:32,
                  ?RESPONSE_CODE_OK:16>>,
            %% FIXME check if vhost is alive (see rabbit_reader:is_vhost_alive/2)
            {Connection#stream_connection{connection_step = opened,
                                          virtual_host = VirtualHost},
             F}
        catch
            exit:_ ->
                Fr = <<?RESPONSE:1,
                       ?COMMAND_OPEN:15,
                       ?VERSION_1:16,
                       CorrelationId:32,
                       ?RESPONSE_VHOST_ACCESS_FAILURE:16>>,
                {Connection#stream_connection{connection_step = failure}, Fr}
        end,

    frame(Transport, Connection1, Frame),

    {Connection1, State, Rest};
handle_frame_pre_auth(_Transport,
                      Connection,
                      State,
                      <<?REQUEST:1, ?COMMAND_HEARTBEAT:15, ?VERSION_1:16>>,
                      Rest) ->
    rabbit_log:info("Received heartbeat frame pre auth~n"),
    {Connection, State, Rest};
handle_frame_pre_auth(_Transport, Connection, State, Frame, Rest) ->
    rabbit_log:warning("unknown frame ~p ~p, closing connection.~n",
                       [Frame, Rest]),
    {Connection#stream_connection{connection_step = failure}, State,
     Rest}.

auth_fail(Username, Msg, Args, Connection, ConnectionState) ->
    notify_auth_result(Username,
                       user_authentication_failure,
                       [{error, rabbit_misc:format(Msg, Args)}],
                       Connection,
                       ConnectionState).

notify_auth_result(Username,
                   AuthResult,
                   ExtraProps,
                   Connection,
                   ConnectionState) ->
    EventProps =
        [{connection_type, network},
         {name,
          case Username of
              none ->
                  '';
              _ ->
                  Username
          end}]
        ++ [case Item of
                name ->
                    {connection_name, i(name, Connection, ConnectionState)};
                _ ->
                    {Item, i(Item, Connection, ConnectionState)}
            end
            || Item <- ?AUTH_NOTIFICATION_INFO_KEYS]
        ++ ExtraProps,
    rabbit_event:notify(AuthResult,
                        [P || {_, V} = P <- EventProps, V =/= '']).

handle_frame_post_auth(Transport,
                       #stream_connection{user = User,
                                          publishers = Publishers0,
                                          publisher_to_ids = RefIds0} =
                           Connection0,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_DECLARE_PUBLISHER:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         PublisherId:8,
                         ReferenceSize:16,
                         Reference:ReferenceSize/binary,
                         StreamSize:16,
                         Stream:StreamSize/binary>>,
                       Rest) ->
    case rabbit_stream_utils:check_write_permitted(stream_r(Stream,
                                                            Connection0),
                                                   User, #{})
    of
        ok ->
            case {maps:is_key(PublisherId, Publishers0),
                  maps:is_key({Stream, Reference}, RefIds0)}
            of
                {false, false} ->
                    case lookup_leader(Stream, Connection0) of
                        cluster_not_found ->
                            response(Transport,
                                     Connection0,
                                     ?COMMAND_DECLARE_PUBLISHER,
                                     CorrelationId,
                                     ?RESPONSE_CODE_STREAM_DOES_NOT_EXIST),
                            {Connection0, State, Rest};
                        {ClusterLeader,
                         #stream_connection{publishers = Publishers0,
                                            publisher_to_ids = RefIds0} =
                             Connection1} ->
                            {PublisherReference, RefIds1} =
                                case Reference of
                                    <<"">> ->
                                        {undefined, RefIds0};
                                    _ ->
                                        {Reference,
                                         RefIds0#{{Stream, Reference} =>
                                                      PublisherId}}
                                end,
                            Publisher =
                                #publisher{publisher_id = PublisherId,
                                           stream = Stream,
                                           reference = PublisherReference,
                                           leader = ClusterLeader,
                                           message_counters =
                                               atomics:new(3,
                                                           [{signed, false}])},
                            response(Transport,
                                     Connection0,
                                     ?COMMAND_DECLARE_PUBLISHER,
                                     CorrelationId,
                                     ?RESPONSE_CODE_OK),
                            rabbit_stream_metrics:publisher_created(self(),
                                                                    stream_r(Stream,
                                                                             Connection1),
                                                                    PublisherId,
                                                                    PublisherReference),
                            {Connection1#stream_connection{publishers =
                                                               Publishers0#{PublisherId
                                                                                =>
                                                                                Publisher},
                                                           publisher_to_ids =
                                                               RefIds1},
                             State, Rest}
                    end;
                {_, _} ->
                    response(Transport,
                             Connection0,
                             ?COMMAND_DECLARE_PUBLISHER,
                             CorrelationId,
                             ?RESPONSE_CODE_PRECONDITION_FAILED),
                    {Connection0, State, Rest}
            end;
        error ->
            response(Transport,
                     Connection0,
                     ?COMMAND_DECLARE_PUBLISHER,
                     CorrelationId,
                     ?RESPONSE_CODE_ACCESS_REFUSED),
            {Connection0, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          credits = Credits,
                                          virtual_host = VirtualHost,
                                          user = User,
                                          publishers = Publishers} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_PUBLISH:15,
                         ?VERSION_1:16,
                         PublisherId:8/unsigned,
                         MessageCount:32,
                         Messages/binary>>,
                       Rest) ->
    case Publishers of
        #{PublisherId := Publisher} ->
            #publisher{stream = Stream,
                       reference = Reference,
                       leader = Leader,
                       message_counters = Counters} =
                Publisher,
            increase_messages_published(Counters, MessageCount),
            case rabbit_stream_utils:check_write_permitted(#resource{name =
                                                                         Stream,
                                                                     kind =
                                                                         queue,
                                                                     virtual_host
                                                                         =
                                                                         VirtualHost},
                                                           User, #{})
            of
                ok ->
                    rabbit_stream_utils:write_messages(Leader,
                                                       Reference,
                                                       PublisherId,
                                                       Messages),
                    sub_credits(Credits, MessageCount),
                    {Connection, State, Rest};
                error ->
                    FrameSize = 2 + 2 + 1 + 4 + (8 + 2) * MessageCount,
                    Details =
                        generate_publishing_error_details(<<>>,
                                                          ?RESPONSE_CODE_ACCESS_REFUSED,
                                                          Messages),
                    Transport:send(S,
                                   [<<FrameSize:32,
                                      ?REQUEST:1,
                                      ?COMMAND_PUBLISH_ERROR:15,
                                      ?VERSION_1:16,
                                      PublisherId:8,
                                      MessageCount:32,
                                      Details/binary>>]),
                    increase_messages_errored(Counters, MessageCount),
                    {Connection, State, Rest}
            end;
        _ ->
            FrameSize = 2 + 2 + 1 + 4 + (8 + 2) * MessageCount,
            Details =
                generate_publishing_error_details(<<>>,
                                                  ?RESPONSE_CODE_PUBLISHER_DOES_NOT_EXIST,
                                                  Messages),
            Transport:send(S,
                           [<<FrameSize:32,
                              ?REQUEST:1,
                              ?COMMAND_PUBLISH_ERROR:15,
                              ?VERSION_1:16,
                              PublisherId:8,
                              MessageCount:32,
                              Details/binary>>]),
            {Connection, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          virtual_host = VirtualHost,
                                          user = User} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_QUERY_PUBLISHER_SEQUENCE:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         ReferenceSize:16,
                         Reference:ReferenceSize/binary,
                         StreamSize:16,
                         Stream:StreamSize/binary>>,
                       Rest) ->
    FrameSize = ?RESPONSE_FRAME_SIZE + 8,
    {ResponseCode, Sequence} =
        case rabbit_stream_utils:check_read_permitted(#resource{name = Stream,
                                                                kind = queue,
                                                                virtual_host =
                                                                    VirtualHost},
                                                      User, #{})
        of
            ok ->
                case rabbit_stream_manager:lookup_local_member(VirtualHost,
                                                               Stream)
                of
                    {error, not_found} ->
                        {?RESPONSE_CODE_STREAM_DOES_NOT_EXIST, 0};
                    {ok, LocalMemberPid} ->
                        {?RESPONSE_CODE_OK,
                         case osiris:fetch_writer_seq(LocalMemberPid, Reference)
                         of
                             undefined ->
                                 0;
                             Offt ->
                                 Offt
                         end}
                end;
            error ->
                {?RESPONSE_CODE_ACCESS_REFUSED, 0}
        end,
    Transport:send(S,
                   [<<FrameSize:32,
                      ?RESPONSE:1,
                      ?COMMAND_QUERY_PUBLISHER_SEQUENCE:15,
                      ?VERSION_1:16>>,
                    <<CorrelationId:32>>,
                    <<ResponseCode:16>>,
                    <<Sequence:64>>]),
    {Connection, State, Rest};
handle_frame_post_auth(Transport,
                       #stream_connection{publishers = Publishers,
                                          publisher_to_ids = PubToIds} =
                           Connection0,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_DELETE_PUBLISHER:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         PublisherId:8>>,
                       Rest) ->
    case Publishers of
        #{PublisherId := #publisher{stream = Stream, reference = Ref}} ->
            Connection1 =
                Connection0#stream_connection{publishers =
                                                  maps:remove(PublisherId,
                                                              Publishers),
                                              publisher_to_ids =
                                                  maps:remove({Stream, Ref},
                                                              PubToIds)},
            Connection2 =
                maybe_clean_connection_from_stream(Stream, Connection1),
            response(Transport,
                     Connection1,
                     ?COMMAND_DELETE_PUBLISHER,
                     CorrelationId,
                     ?RESPONSE_CODE_OK),
            rabbit_stream_metrics:publisher_deleted(self(),
                                                    stream_r(Stream,
                                                             Connection2),
                                                    PublisherId),
            {Connection2, State, Rest};
        _ ->
            response(Transport,
                     Connection0,
                     ?COMMAND_DELETE_PUBLISHER,
                     CorrelationId,
                     ?RESPONSE_CODE_PUBLISHER_DOES_NOT_EXIST),
            {Connection0, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = Socket,
                                          stream_subscriptions =
                                              StreamSubscriptions,
                                          virtual_host = VirtualHost,
                                          user = User,
                                          send_file_oct = SendFileOct} =
                           Connection,
                       #stream_connection_state{consumers = Consumers} = State,
                       <<?REQUEST:1,
                         ?COMMAND_SUBSCRIBE:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         SubscriptionId:8/unsigned,
                         StreamSize:16,
                         Stream:StreamSize/binary,
                         OffsetType:16/signed,
                         OffsetAndCredit/binary>>,
                       Rest) ->
    %% FIXME check the max number of subs is not reached already
    case rabbit_stream_utils:check_read_permitted(#resource{name = Stream,
                                                            kind = queue,
                                                            virtual_host =
                                                                VirtualHost},
                                                  User, #{})
    of
        ok ->
            case rabbit_stream_manager:lookup_local_member(VirtualHost, Stream)
            of
                {error, not_available} ->
                    response(Transport,
                             Connection,
                             ?COMMAND_SUBSCRIBE,
                             CorrelationId,
                             ?RESPONSE_CODE_STREAM_NOT_AVAILABLE),
                    {Connection, State, Rest};
                {error, not_found} ->
                    response(Transport,
                             Connection,
                             ?COMMAND_SUBSCRIBE,
                             CorrelationId,
                             ?RESPONSE_CODE_STREAM_DOES_NOT_EXIST),
                    {Connection, State, Rest};
                {ok, LocalMemberPid} ->
                    case subscription_exists(StreamSubscriptions,
                                             SubscriptionId)
                    of
                        true ->
                            response(Transport,
                                     Connection,
                                     ?COMMAND_SUBSCRIBE,
                                     CorrelationId,
                                     ?RESPONSE_CODE_SUBSCRIPTION_ID_ALREADY_EXISTS),
                            {Connection, State, Rest};
                        false ->
                            {OffsetSpec, Credit} =
                                case OffsetType of
                                    ?OFFSET_TYPE_FIRST ->
                                        <<Crdt:16>> = OffsetAndCredit,
                                        {first, Crdt};
                                    ?OFFSET_TYPE_LAST ->
                                        <<Crdt:16>> = OffsetAndCredit,
                                        {last, Crdt};
                                    ?OFFSET_TYPE_NEXT ->
                                        <<Crdt:16>> = OffsetAndCredit,
                                        {next, Crdt};
                                    ?OFFSET_TYPE_OFFSET ->
                                        <<Offset:64/unsigned, Crdt:16>> =
                                            OffsetAndCredit,
                                        {Offset, Crdt};
                                    ?OFFSET_TYPE_TIMESTAMP ->
                                        <<Timestamp:64/signed, Crdt:16>> =
                                            OffsetAndCredit,
                                        {{timestamp, Timestamp}, Crdt}
                                end,
                            rabbit_log:info("Creating subscription ~p to ~p, with offset specificat"
                                            "ion ~p~n",
                                            [SubscriptionId, Stream,
                                             OffsetSpec]),
                            {ok, Segment} =
                                osiris:init_reader(LocalMemberPid, OffsetSpec),
                            rabbit_log:info("Next offset for subscription ~p is ~p~n",
                                            [SubscriptionId,
                                             osiris_log:next_offset(Segment)]),
                            ConsumerCounters =
                                atomics:new(2, [{signed, false}]),
                            ConsumerState =
                                #consumer{member_pid = LocalMemberPid,
                                          offset = OffsetSpec,
                                          subscription_id = SubscriptionId,
                                          socket = Socket,
                                          segment = Segment,
                                          credit = Credit,
                                          stream = Stream,
                                          counters = ConsumerCounters},

                            Connection1 =
                                maybe_monitor_stream(LocalMemberPid, Stream,
                                                     Connection),

                            response_ok(Transport,
                                        Connection,
                                        ?COMMAND_SUBSCRIBE,
                                        CorrelationId),

                            rabbit_log:info("Distributing existing messages to subscription "
                                            "~p~n",
                                            [SubscriptionId]),
                            {{segment, Segment1}, {credit, Credit1}} =
                                send_chunks(Transport, ConsumerState,
                                            SendFileOct),
                            ConsumerState1 =
                                ConsumerState#consumer{segment = Segment1,
                                                       credit = Credit1},
                            Consumers1 =
                                Consumers#{SubscriptionId => ConsumerState1},

                            StreamSubscriptions1 =
                                case StreamSubscriptions of
                                    #{Stream := SubscriptionIds} ->
                                        StreamSubscriptions#{Stream =>
                                                                 [SubscriptionId]
                                                                 ++ SubscriptionIds};
                                    _ ->
                                        StreamSubscriptions#{Stream =>
                                                                 [SubscriptionId]}
                                end,

                            #consumer{counters = ConsumerCounters1} =
                                ConsumerState1,

                            ConsumerOffset = osiris_log:next_offset(Segment1),

                            rabbit_log:info("Subscription ~p is now at offset ~p with ~p message(s) "
                                            "distributed after subscription~n",
                                            [SubscriptionId, ConsumerOffset,
                                             messages_consumed(ConsumerCounters1)]),

                            rabbit_stream_metrics:consumer_created(self(),
                                                                   stream_r(Stream,
                                                                            Connection1),
                                                                   SubscriptionId,
                                                                   Credit1,
                                                                   messages_consumed(ConsumerCounters1),
                                                                   ConsumerOffset),
                            {Connection1#stream_connection{stream_subscriptions
                                                               =
                                                               StreamSubscriptions1},
                             State#stream_connection_state{consumers =
                                                               Consumers1},
                             Rest}
                    end
            end;
        error ->
            response(Transport,
                     Connection,
                     ?COMMAND_SUBSCRIBE,
                     CorrelationId,
                     ?RESPONSE_CODE_ACCESS_REFUSED),
            {Connection, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          send_file_oct = SendFileOct} =
                           Connection,
                       #stream_connection_state{consumers = Consumers} = State,
                       <<?REQUEST:1,
                         ?COMMAND_CREDIT:15,
                         ?VERSION_1:16,
                         SubscriptionId:8/unsigned,
                         Credit:16/signed>>,
                       Rest) ->
    case Consumers of
        #{SubscriptionId := Consumer} ->
            #consumer{credit = AvailableCredit} = Consumer,

            {{segment, Segment1}, {credit, Credit1}} =
                send_chunks(Transport,
                            Consumer,
                            AvailableCredit + Credit,
                            SendFileOct),

            Consumer1 = Consumer#consumer{segment = Segment1, credit = Credit1},
            {Connection,
             State#stream_connection_state{consumers =
                                               Consumers#{SubscriptionId =>
                                                              Consumer1}},
             Rest};
        _ ->
            rabbit_log:warning("Giving credit to unknown subscription: ~p~n",
                               [SubscriptionId]),
            Frame =
                <<?RESPONSE:1,
                  ?COMMAND_CREDIT:15,
                  ?VERSION_1:16,
                  ?RESPONSE_CODE_SUBSCRIPTION_ID_DOES_NOT_EXIST:16,
                  SubscriptionId:8>>,
            FrameSize = byte_size(Frame),
            Transport:send(S, [<<FrameSize:32>>, Frame]),
            {Connection, State, Rest}
    end;
handle_frame_post_auth(_Transport,
                       #stream_connection{virtual_host = VirtualHost,
                                          user = User} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_COMMIT_OFFSET:15,
                         ?VERSION_1:16,
                         _CorrelationId:32,
                         ReferenceSize:16,
                         Reference:ReferenceSize/binary,
                         StreamSize:16,
                         Stream:StreamSize/binary,
                         Offset:64>>,
                       Rest) ->
    case rabbit_stream_utils:check_write_permitted(#resource{name =
                                                                 Stream,
                                                             kind = queue,
                                                             virtual_host =
                                                                 VirtualHost},
                                                   User, #{})
    of
        ok ->
            case lookup_leader(Stream, Connection) of
                cluster_not_found ->
                    rabbit_log:info("Could not find leader to commit offset on ~p~n",
                                    [Stream]),
                    %% FIXME commit offset is fire-and-forget, so no response even if error, change this?
                    {Connection, State, Rest};
                {ClusterLeader, Connection1} ->
                    osiris:write_tracking(ClusterLeader, Reference, Offset),
                    {Connection1, State, Rest}
            end;
        error ->
            %% FIXME commit offset is fire-and-forget, so no response even if error, change this?
            rabbit_log:info("Not authorized to commit offset on ~p~n",
                            [Stream]),
            {Connection, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          virtual_host = VirtualHost,
                                          user = User} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_QUERY_OFFSET:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         ReferenceSize:16,
                         Reference:ReferenceSize/binary,
                         StreamSize:16,
                         Stream:StreamSize/binary>>,
                       Rest) ->
    FrameSize = ?RESPONSE_FRAME_SIZE + 8,
    {ResponseCode, Offset} =
        case rabbit_stream_utils:check_read_permitted(#resource{name = Stream,
                                                                kind = queue,
                                                                virtual_host =
                                                                    VirtualHost},
                                                      User, #{})
        of
            ok ->
                case rabbit_stream_manager:lookup_local_member(VirtualHost,
                                                               Stream)
                of
                    {error, not_found} ->
                        {?RESPONSE_CODE_STREAM_DOES_NOT_EXIST, 0};
                    {ok, LocalMemberPid} ->
                        {?RESPONSE_CODE_OK,
                         case osiris:read_tracking(LocalMemberPid, Reference) of
                             undefined ->
                                 0;
                             Offt ->
                                 Offt
                         end}
                end;
            error ->
                {?RESPONSE_CODE_ACCESS_REFUSED, 0}
        end,
    Transport:send(S,
                   [<<FrameSize:32,
                      ?RESPONSE:1,
                      ?COMMAND_QUERY_OFFSET:15,
                      ?VERSION_1:16>>,
                    <<CorrelationId:32>>,
                    <<ResponseCode:16>>,
                    <<Offset:64>>]),
    {Connection, State, Rest};
handle_frame_post_auth(Transport,
                       #stream_connection{stream_subscriptions =
                                              StreamSubscriptions} =
                           Connection,
                       #stream_connection_state{consumers = Consumers} = State,
                       <<?REQUEST:1,
                         ?COMMAND_UNSUBSCRIBE:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         SubscriptionId:8/unsigned>>,
                       Rest) ->
    case subscription_exists(StreamSubscriptions, SubscriptionId) of
        false ->
            response(Transport,
                     Connection,
                     ?COMMAND_UNSUBSCRIBE,
                     CorrelationId,
                     ?RESPONSE_CODE_SUBSCRIPTION_ID_DOES_NOT_EXIST),
            {Connection, State, Rest};
        true ->
            #{SubscriptionId := Consumer} = Consumers,
            Stream = Consumer#consumer.stream,
            #{Stream := SubscriptionsForThisStream} = StreamSubscriptions,
            SubscriptionsForThisStream1 =
                lists:delete(SubscriptionId, SubscriptionsForThisStream),
            StreamSubscriptions1 =
                case length(SubscriptionsForThisStream1) of
                    0 ->
                        % no more subscription for this stream
                        maps:remove(Stream, StreamSubscriptions);
                    _ ->
                        StreamSubscriptions#{Stream =>
                                                 SubscriptionsForThisStream1}
                end,
            Connection1 =
                Connection#stream_connection{stream_subscriptions =
                                                 StreamSubscriptions1},
            Consumers1 = maps:remove(SubscriptionId, Consumers),
            Connection2 =
                maybe_clean_connection_from_stream(Stream, Connection1),
            rabbit_stream_metrics:consumer_cancelled(self(),
                                                     stream_r(Stream,
                                                              Connection2),
                                                     SubscriptionId),
            response_ok(Transport,
                        Connection,
                        ?COMMAND_SUBSCRIBE,
                        CorrelationId),
            {Connection2, State#stream_connection_state{consumers = Consumers1},
             Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{virtual_host = VirtualHost,
                                          user =
                                              #user{username = Username} =
                                                  User} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_CREATE_STREAM:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         StreamSize:16,
                         Stream:StreamSize/binary,
                         ArgumentsCount:32,
                         ArgumentsBinary/binary>>,
                       Rest) ->
    case rabbit_stream_utils:enforce_correct_stream_name(Stream) of
        {ok, StreamName} ->
            {Arguments, _Rest} =
                rabbit_stream_utils:parse_map(ArgumentsBinary, ArgumentsCount),
            case rabbit_stream_utils:check_configure_permitted(#resource{name =
                                                                             StreamName,
                                                                         kind =
                                                                             queue,
                                                                         virtual_host
                                                                             =
                                                                             VirtualHost},
                                                               User, #{})
            of
                ok ->
                    case rabbit_stream_manager:create(VirtualHost,
                                                      StreamName,
                                                      Arguments,
                                                      Username)
                    of
                        {ok,
                         #{leader_node := LeaderPid,
                           replica_nodes := ReturnedReplicas}} ->
                            rabbit_log:info("Created cluster with leader on ~p and replicas "
                                            "on ~p~n",
                                            [LeaderPid, ReturnedReplicas]),
                            response_ok(Transport,
                                        Connection,
                                        ?COMMAND_CREATE_STREAM,
                                        CorrelationId),
                            {Connection, State, Rest};
                        {error, validation_failed} ->
                            response(Transport,
                                     Connection,
                                     ?COMMAND_CREATE_STREAM,
                                     CorrelationId,
                                     ?RESPONSE_CODE_PRECONDITION_FAILED),
                            {Connection, State, Rest};
                        {error, reference_already_exists} ->
                            response(Transport,
                                     Connection,
                                     ?COMMAND_CREATE_STREAM,
                                     CorrelationId,
                                     ?RESPONSE_CODE_STREAM_ALREADY_EXISTS),
                            {Connection, State, Rest};
                        {error, _} ->
                            response(Transport,
                                     Connection,
                                     ?COMMAND_CREATE_STREAM,
                                     CorrelationId,
                                     ?RESPONSE_CODE_INTERNAL_ERROR),
                            {Connection, State, Rest}
                    end;
                error ->
                    response(Transport,
                             Connection,
                             ?COMMAND_CREATE_STREAM,
                             CorrelationId,
                             ?RESPONSE_CODE_ACCESS_REFUSED),
                    {Connection, State, Rest}
            end;
        _ ->
            response(Transport,
                     Connection,
                     ?COMMAND_CREATE_STREAM,
                     CorrelationId,
                     ?RESPONSE_CODE_PRECONDITION_FAILED),
            {Connection, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          virtual_host = VirtualHost,
                                          user =
                                              #user{username = Username} =
                                                  User} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_DELETE_STREAM:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         StreamSize:16,
                         Stream:StreamSize/binary>>,
                       Rest) ->
    case rabbit_stream_utils:check_configure_permitted(#resource{name =
                                                                     Stream,
                                                                 kind = queue,
                                                                 virtual_host =
                                                                     VirtualHost},
                                                       User, #{})
    of
        ok ->
            case rabbit_stream_manager:delete(VirtualHost, Stream, Username) of
                {ok, deleted} ->
                    response_ok(Transport,
                                Connection,
                                ?COMMAND_DELETE_STREAM,
                                CorrelationId),
                    {Connection1, State1} =
                        case
                            clean_state_after_stream_deletion_or_failure(Stream,
                                                                         Connection,
                                                                         State)
                        of
                            {cleaned, NewConnection, NewState} ->
                                StreamSize = byte_size(Stream),
                                FrameSize = 2 + 2 + 2 + 2 + StreamSize,
                                Transport:send(S,
                                               [<<FrameSize:32,
                                                  ?REQUEST:1,
                                                  ?COMMAND_METADATA_UPDATE:15,
                                                  ?VERSION_1:16,
                                                  ?RESPONSE_CODE_STREAM_NOT_AVAILABLE:16,
                                                  StreamSize:16,
                                                  Stream/binary>>]),
                                {NewConnection, NewState};
                            {not_cleaned, SameConnection, SameState} ->
                                {SameConnection, SameState}
                        end,
                    {Connection1, State1, Rest};
                {error, reference_not_found} ->
                    response(Transport,
                             Connection,
                             ?COMMAND_DELETE_STREAM,
                             CorrelationId,
                             ?RESPONSE_CODE_STREAM_DOES_NOT_EXIST),
                    {Connection, State, Rest}
            end;
        error ->
            response(Transport,
                     Connection,
                     ?COMMAND_DELETE_STREAM,
                     CorrelationId,
                     ?RESPONSE_CODE_ACCESS_REFUSED),
            {Connection, State, Rest}
    end;
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          virtual_host = VirtualHost} =
                           Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_METADATA:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         StreamCount:32,
                         BinaryStreams/binary>>,
                       Rest) ->
    Streams = rabbit_stream_utils:extract_stream_list(BinaryStreams, []),

    Topology =
        lists:foldl(fun(Stream, Acc) ->
                       Acc#{Stream =>
                                rabbit_stream_manager:topology(VirtualHost,
                                                               Stream)}
                    end,
                    #{}, Streams),

    %% get the nodes involved in the streams
    NodesMap =
        lists:foldl(fun(Stream, Acc) ->
                       case maps:get(Stream, Topology) of
                           {ok,
                            #{leader_node := undefined,
                              replica_nodes := ReplicaNodes}} ->
                               lists:foldl(fun(ReplicaNode, NodesAcc) ->
                                              maps:put(ReplicaNode, ok,
                                                       NodesAcc)
                                           end,
                                           Acc, ReplicaNodes);
                           {ok,
                            #{leader_node := LeaderNode,
                              replica_nodes := ReplicaNodes}} ->
                               Acc1 = maps:put(LeaderNode, ok, Acc),
                               lists:foldl(fun(ReplicaNode, NodesAcc) ->
                                              maps:put(ReplicaNode, ok,
                                                       NodesAcc)
                                           end,
                                           Acc1, ReplicaNodes);
                           {error, _} -> Acc
                       end
                    end,
                    #{}, Streams),

    Nodes = maps:keys(NodesMap),
    {NodesInfo, _} =
        lists:foldl(fun(Node, {Acc, Index}) ->
                       Host = rpc:call(Node, rabbit_stream, host, []),
                       Port = rpc:call(Node, rabbit_stream, port, []),
                       case {is_binary(Host), is_integer(Port)} of
                           {true, true} ->
                               {Acc#{Node =>
                                         {{index, Index}, {host, Host},
                                          {port, Port}}},
                                Index + 1};
                           _ ->
                               rabbit_log:warning("Error when retrieving broker metadata: ~p ~p~n",
                                                  [Host, Port]),
                               {Acc, Index}
                       end
                    end,
                    {#{}, 0}, Nodes),

    BrokersCount = map_size(NodesInfo),
    BrokersBin =
        maps:fold(fun(_K, {{index, Index}, {host, Host}, {port, Port}},
                      Acc) ->
                     HostLength = byte_size(Host),
                     <<Acc/binary,
                       Index:16,
                       HostLength:16,
                       Host:HostLength/binary,
                       Port:32>>
                  end,
                  <<BrokersCount:32>>, NodesInfo),

    MetadataBin =
        lists:foldl(fun(Stream, Acc) ->
                       StreamLength = byte_size(Stream),
                       case maps:get(Stream, Topology) of
                           {error, stream_not_found} ->
                               <<Acc/binary,
                                 StreamLength:16,
                                 Stream:StreamLength/binary,
                                 ?RESPONSE_CODE_STREAM_DOES_NOT_EXIST:16,
                                 (-1):16,
                                 0:32>>;
                           {error, stream_not_available} ->
                               <<Acc/binary,
                                 StreamLength:16,
                                 Stream:StreamLength/binary,
                                 ?RESPONSE_CODE_STREAM_NOT_AVAILABLE:16,
                                 (-1):16,
                                 0:32>>;
                           {ok,
                            #{leader_node := LeaderNode,
                              replica_nodes := Replicas}} ->
                               LeaderIndex =
                                   case NodesInfo of
                                       #{LeaderNode := NodeInfo} ->
                                           {{index, LeaderIdx}, {host, _},
                                            {port, _}} =
                                               NodeInfo,
                                           LeaderIdx;
                                       _ -> -1
                                   end,
                               {ReplicasBinary, ReplicasCount} =
                                   lists:foldl(fun(Replica, {Bin, Count}) ->
                                                  case NodesInfo of
                                                      #{Replica := NI} ->
                                                          {{index,
                                                            ReplicaIndex},
                                                           {host, _},
                                                           {port, _}} =
                                                              NI,
                                                          {<<Bin/binary,
                                                             ReplicaIndex:16>>,
                                                           Count + 1};
                                                      _ -> {Bin, Count}
                                                  end
                                               end,
                                               {<<>>, 0}, Replicas),
                               <<Acc/binary,
                                 StreamLength:16,
                                 Stream:StreamLength/binary,
                                 ?RESPONSE_CODE_OK:16,
                                 LeaderIndex:16,
                                 ReplicasCount:32,
                                 ReplicasBinary/binary>>
                       end
                    end,
                    <<StreamCount:32>>, Streams),
    Frame =
        <<?RESPONSE:1,
          ?COMMAND_METADATA:15,
          ?VERSION_1:16,
          CorrelationId:32,
          BrokersBin/binary,
          MetadataBin/binary>>,
    FrameSize = byte_size(Frame),
    Transport:send(S, <<FrameSize:32, Frame/binary>>),
    {Connection, State, Rest};
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          virtual_host = VirtualHost} =
                           Connection,
                       State,
                       <<?COMMAND_ROUTE:16,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         RoutingKeySize:16,
                         RoutingKey:RoutingKeySize/binary,
                         SuperStreamSize:16,
                         SuperStream:SuperStreamSize/binary>>,
                       Rest) ->
    {ResponseCode, StreamBin} =
        case rabbit_stream_manager:route(RoutingKey, VirtualHost, SuperStream)
        of
            {ok, no_route} ->
                {?RESPONSE_CODE_OK, <<(-1):16>>};
            {ok, Stream} ->
                StreamSize = byte_size(Stream),
                {?RESPONSE_CODE_OK,
                 <<StreamSize:16, Stream:StreamSize/binary>>};
            {error, _} ->
                {?RESPONSE_CODE_STREAM_DOES_NOT_EXIST, <<(-1):16>>}
        end,

    Frame =
        <<?COMMAND_ROUTE:16,
          ?VERSION_1:16,
          CorrelationId:32,
          ResponseCode:16,
          StreamBin/binary>>,
    FrameSize = byte_size(Frame),
    Transport:send(S, <<FrameSize:32, Frame/binary>>),
    {Connection, State, Rest};
handle_frame_post_auth(Transport,
                       #stream_connection{socket = S,
                                          virtual_host = VirtualHost} =
                           Connection,
                       State,
                       <<?COMMAND_PARTITIONS:16,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         SuperStreamSize:16,
                         SuperStream:SuperStreamSize/binary>>,
                       Rest) ->
    {ResponseCode, PartitionsBin} =
        case rabbit_stream_manager:partitions(VirtualHost, SuperStream) of
            {ok, []} ->
                {?RESPONSE_CODE_OK, <<0:32>>};
            {ok, Streams} ->
                StreamCount = length(Streams),
                Bin = lists:foldl(fun(Stream, Acc) ->
                                     StreamSize = byte_size(Stream),
                                     <<Acc/binary, StreamSize:16,
                                       Stream:StreamSize/binary>>
                                  end,
                                  <<StreamCount:32>>, Streams),
                {?RESPONSE_CODE_OK, Bin};
            {error, _} ->
                {?RESPONSE_CODE_STREAM_DOES_NOT_EXIST, <<0:32>>}
        end,

    Frame =
        <<?COMMAND_PARTITIONS:16,
          ?VERSION_1:16,
          CorrelationId:32,
          ResponseCode:16,
          PartitionsBin/binary>>,
    FrameSize = byte_size(Frame),
    Transport:send(S, <<FrameSize:32, Frame/binary>>),
    {Connection, State, Rest};
handle_frame_post_auth(Transport,
                       Connection,
                       State,
                       <<?REQUEST:1,
                         ?COMMAND_CLOSE:15,
                         ?VERSION_1:16,
                         CorrelationId:32,
                         ClosingCode:16,
                         ClosingReasonLength:16,
                         ClosingReason:ClosingReasonLength/binary>>,
                       _Rest) ->
    rabbit_log:info("Received close command ~p ~p~n",
                    [ClosingCode, ClosingReason]),
    Frame =
        <<?RESPONSE:1,
          ?COMMAND_CLOSE:15,
          ?VERSION_1:16,
          CorrelationId:32,
          ?RESPONSE_CODE_OK:16>>,
    frame(Transport, Connection, Frame),
    {Connection#stream_connection{connection_step = closing}, State,
     <<>>}; %% we ignore any subsequent frames
handle_frame_post_auth(_Transport,
                       Connection,
                       State,
                       <<?REQUEST:1, ?COMMAND_HEARTBEAT:15, ?VERSION_1:16>>,
                       Rest) ->
    rabbit_log:info("Received heartbeat frame post auth~n"),
    {Connection, State, Rest};
handle_frame_post_auth(Transport, Connection, State, Frame, Rest) ->
    rabbit_log:warning("unknown frame ~p ~p, sending close command.~n",
                       [Frame, Rest]),
    CloseReason = <<"unknown frame">>,
    CloseReasonLength = byte_size(CloseReason),
    CloseFrame =
        <<?REQUEST:1,
          ?COMMAND_CLOSE:15,
          ?VERSION_1:16,
          1:32,
          ?RESPONSE_CODE_UNKNOWN_FRAME:16,
          CloseReasonLength:16,
          CloseReason:CloseReasonLength/binary>>,
    frame(Transport, Connection, CloseFrame),
    {Connection#stream_connection{connection_step = close_sent}, State,
     Rest}.

notify_connection_closed(#stream_connection{name = Name,
                                            publishers = Publishers} =
                             Connection,
                         #stream_connection_state{consumers = Consumers} =
                             ConnectionState) ->
    rabbit_core_metrics:connection_closed(self()),
    [rabbit_stream_metrics:consumer_cancelled(self(),
                                              stream_r(S, Connection), SubId)
     || #consumer{stream = S, subscription_id = SubId}
            <- maps:values(Consumers)],
    [rabbit_stream_metrics:publisher_deleted(self(),
                                             stream_r(S, Connection), PubId)
     || #publisher{stream = S, publisher_id = PubId}
            <- maps:values(Publishers)],
    ClientProperties = i(client_properties, Connection, ConnectionState),
    EventProperties =
        [{name, Name},
         {pid, self()},
         {node, node()},
         {client_properties, ClientProperties}],
    rabbit_event:notify(connection_closed,
                        augment_infos_with_user_provided_connection_name(EventProperties,
                                                                         Connection)).

handle_frame_post_close(_Transport,
                        Connection,
                        State,
                        <<?RESPONSE:1,
                          ?COMMAND_CLOSE:15,
                          ?VERSION_1:16,
                          _CorrelationId:32,
                          _ResponseCode:16>>,
                        Rest) ->
    rabbit_log:info("Received close confirmation~n"),
    {Connection#stream_connection{connection_step = closing_done}, State,
     Rest};
handle_frame_post_close(_Transport,
                        Connection,
                        State,
                        <<?REQUEST:1, ?COMMAND_HEARTBEAT:15, ?VERSION_1:16>>,
                        Rest) ->
    rabbit_log:info("Received heartbeat frame post close~n"),
    {Connection, State, Rest};
handle_frame_post_close(_Transport, Connection, State, Frame, Rest) ->
    rabbit_log:warning("ignored frame on close ~p ~p.~n", [Frame, Rest]),
    {Connection, State, Rest}.

stream_r(Stream, #stream_connection{virtual_host = VHost}) ->
    #resource{name = Stream,
              kind = queue,
              virtual_host = VHost}.

clean_state_after_stream_deletion_or_failure(Stream,
                                             #stream_connection{stream_subscriptions
                                                                    =
                                                                    StreamSubscriptions,
                                                                publishers =
                                                                    Publishers,
                                                                publisher_to_ids
                                                                    =
                                                                    PublisherToIds,
                                                                stream_leaders =
                                                                    Leaders} =
                                                 C0,
                                             #stream_connection_state{consumers
                                                                          =
                                                                          Consumers} =
                                                 S0) ->
    {SubscriptionsCleaned, C1, S1} =
        case stream_has_subscriptions(Stream, C0) of
            true ->
                #{Stream := SubscriptionIds} = StreamSubscriptions,
                [rabbit_stream_metrics:consumer_cancelled(self(),
                                                          stream_r(Stream, C0),
                                                          SubId)
                 || SubId <- SubscriptionIds],
                {true,
                 C0#stream_connection{stream_subscriptions =
                                          maps:remove(Stream,
                                                      StreamSubscriptions)},
                 S0#stream_connection_state{consumers =
                                                maps:without(SubscriptionIds,
                                                             Consumers)}};
            false ->
                {false, C0, S0}
        end,
    {PublishersCleaned, C2, S2} =
        case stream_has_publishers(Stream, C1) of
            true ->
                {PurgedPubs, PurgedPubToIds} =
                    maps:fold(fun(PubId,
                                  #publisher{stream = S, reference = Ref},
                                  {Pubs, PubToIds}) ->
                                 case S of
                                     Stream ->
                                         rabbit_stream_metrics:publisher_deleted(self(),
                                                                                 stream_r(S,
                                                                                          C1),
                                                                                 PubId),
                                         {maps:remove(PubId, Pubs),
                                          maps:remove({Stream, Ref}, PubToIds)};
                                     _ -> {Pubs, PubToIds}
                                 end
                              end,
                              {Publishers, PublisherToIds}, Publishers),
                {true,
                 C1#stream_connection{publishers = PurgedPubs,
                                      publisher_to_ids = PurgedPubToIds},
                 S1};
            false ->
                {false, C1, S1}
        end,
    {LeadersCleaned, Leaders1} =
        case Leaders of
            #{Stream := _} ->
                {true, maps:remove(Stream, Leaders)};
            _ ->
                {false, Leaders}
        end,
    case SubscriptionsCleaned
         orelse PublishersCleaned
         orelse LeadersCleaned
    of
        true ->
            C3 = demonitor_stream(Stream, C2),
            {cleaned, C3#stream_connection{stream_leaders = Leaders1}, S2};
        false ->
            {not_cleaned, C2#stream_connection{stream_leaders = Leaders1}, S2}
    end.

lookup_leader(Stream,
              #stream_connection{stream_leaders = StreamLeaders,
                                 virtual_host = VirtualHost} =
                  Connection) ->
    case maps:get(Stream, StreamLeaders, undefined) of
        undefined ->
            case lookup_leader_from_manager(VirtualHost, Stream) of
                cluster_not_found ->
                    cluster_not_found;
                LeaderPid ->
                    Connection1 =
                        maybe_monitor_stream(LeaderPid, Stream, Connection),
                    {LeaderPid,
                     Connection1#stream_connection{stream_leaders =
                                                       StreamLeaders#{Stream =>
                                                                          LeaderPid}}}
            end;
        LeaderPid ->
            {LeaderPid, Connection}
    end.

lookup_leader_from_manager(VirtualHost, Stream) ->
    rabbit_stream_manager:lookup_leader(VirtualHost, Stream).

maybe_clean_connection_from_stream(Stream,
                                   #stream_connection{stream_leaders =
                                                          Leaders} =
                                       Connection0) ->
    Connection1 =
        case {stream_has_publishers(Stream, Connection0),
              stream_has_subscriptions(Stream, Connection0)}
        of
            {false, false} ->
                demonitor_stream(Stream, Connection0);
            _ ->
                Connection0
        end,
    Connection1#stream_connection{stream_leaders =
                                      maps:remove(Stream, Leaders)}.

maybe_monitor_stream(Pid, Stream,
                     #stream_connection{monitors = Monitors} = Connection) ->
    case lists:member(Stream, maps:values(Monitors)) of
        true ->
            Connection;
        false ->
            MonitorRef = monitor(process, Pid),
            Connection#stream_connection{monitors =
                                             maps:put(MonitorRef, Stream,
                                                      Monitors)}
    end.

demonitor_stream(Stream,
                 #stream_connection{monitors = Monitors0} = Connection) ->
    Monitors =
        maps:fold(fun(MonitorRef, Strm, Acc) ->
                     case Strm of
                         Stream ->
                             demonitor(MonitorRef, [flush]),
                             Acc;
                         _ -> maps:put(MonitorRef, Strm, Acc)
                     end
                  end,
                  #{}, Monitors0),
    Connection#stream_connection{monitors = Monitors}.

stream_has_subscriptions(Stream,
                         #stream_connection{stream_subscriptions =
                                                Subscriptions}) ->
    case Subscriptions of
        #{Stream := StreamSubscriptions}
            when length(StreamSubscriptions) > 0 ->
            true;
        _ ->
            false
    end.

stream_has_publishers(Stream,
                      #stream_connection{publishers = Publishers}) ->
    lists:any(fun(#publisher{stream = S}) ->
                 case S of
                     Stream -> true;
                     _ -> false
                 end
              end,
              maps:values(Publishers)).

demonitor_all_streams(#stream_connection{monitors = Monitors} =
                          Connection) ->
    lists:foreach(fun(MonitorRef) -> demonitor(MonitorRef, [flush]) end,
                  maps:keys(Monitors)),
    Connection#stream_connection{monitors = #{}}.

frame(Transport, #stream_connection{socket = S}, Frame) ->
    FrameSize = byte_size(Frame),
    Transport:send(S, [<<FrameSize:32>>, Frame]).

response_ok(Transport, State, CommandId, CorrelationId) ->
    response(Transport,
             State,
             CommandId,
             CorrelationId,
             ?RESPONSE_CODE_OK).

response(Transport,
         #stream_connection{socket = S},
         CommandId,
         CorrelationId,
         ResponseCode) ->
    Transport:send(S,
                   [<<?RESPONSE_FRAME_SIZE:32,
                      ?RESPONSE:1,
                      CommandId:15,
                      ?VERSION_1:16>>,
                    <<CorrelationId:32>>, <<ResponseCode:16>>]).

subscription_exists(StreamSubscriptions, SubscriptionId) ->
    SubscriptionIds =
        lists:flatten(
            maps:values(StreamSubscriptions)),
    lists:any(fun(Id) -> Id =:= SubscriptionId end, SubscriptionIds).

send_file_callback(Transport,
                   #consumer{socket = S,
                             subscription_id = SubscriptionId,
                             counters = Counters},
                   Counter) ->
    fun(#{chunk_id := FirstOffsetInChunk, num_entries := NumEntries},
        Size) ->
       FrameSize = 2 + 2 + 1 + Size,
       FrameBeginning =
           <<FrameSize:32,
             ?REQUEST:1,
             ?COMMAND_DELIVER:15,
             ?VERSION_1:16,
             SubscriptionId:8/unsigned>>,
       Transport:send(S, FrameBeginning),
       atomics:add(Counter, 1, Size),
       increase_messages_consumed(Counters, NumEntries),
       set_consumer_offset(Counters, FirstOffsetInChunk)
    end.

send_chunks(Transport, #consumer{credit = Credit} = State, Counter) ->
    send_chunks(Transport, State, Credit, Counter).

send_chunks(_Transport, #consumer{segment = Segment}, 0, _Counter) ->
    {{segment, Segment}, {credit, 0}};
send_chunks(Transport,
            #consumer{segment = Segment} = State,
            Credit,
            Counter) ->
    send_chunks(Transport, State, Segment, Credit, true, Counter).

send_chunks(_Transport,
            _State,
            Segment,
            0 = _Credit,
            _Retry,
            _Counter) ->
    {{segment, Segment}, {credit, 0}};
send_chunks(Transport,
            #consumer{socket = S} = State,
            Segment,
            Credit,
            Retry,
            Counter) ->
    case osiris_log:send_file(S, Segment,
                              send_file_callback(Transport, State, Counter))
    of
        {ok, Segment1} ->
            send_chunks(Transport, State, Segment1, Credit - 1, true, Counter);
        {end_of_stream, Segment1} ->
            case Retry of
                true ->
                    timer:sleep(1),
                    send_chunks(Transport,
                                State,
                                Segment1,
                                Credit,
                                false,
                                Counter);
                false ->
                    #consumer{member_pid = LocalMember} = State,
                    osiris:register_offset_listener(LocalMember,
                                                    osiris_log:next_offset(Segment1)),
                    {{segment, Segment1}, {credit, Credit}}
            end
    end.

emit_stats(#stream_connection{publishers = Publishers} = Connection,
           #stream_connection_state{consumers = Consumers} = ConnectionState) ->
    [{_, Pid}, {_, Recv_oct}, {_, Send_oct}, {_, Reductions}] =
        I = infos(?SIMPLE_METRICS, Connection, ConnectionState),
    Infos = infos(?OTHER_METRICS, Connection, ConnectionState),
    rabbit_core_metrics:connection_stats(Pid, Infos),
    rabbit_core_metrics:connection_stats(Pid,
                                         Recv_oct,
                                         Send_oct,
                                         Reductions),
    rabbit_event:notify(connection_stats, Infos ++ I),
    [rabbit_stream_metrics:consumer_updated(self(),
                                            stream_r(S, Connection),
                                            Id,
                                            Credit,
                                            messages_consumed(Counters),
                                            consumer_offset(Counters))
     || #consumer{stream = S,
                  subscription_id = Id,
                  credit = Credit,
                  counters = Counters}
            <- maps:values(Consumers)],
    [rabbit_stream_metrics:publisher_updated(self(),
                                             stream_r(S, Connection),
                                             Id,
                                             PubReference,
                                             messages_published(Counters),
                                             messages_confirmed(Counters),
                                             messages_errored(Counters))
     || #publisher{stream = S,
                   publisher_id = Id,
                   reference = PubReference,
                   message_counters = Counters}
            <- maps:values(Publishers)],
    Connection1 =
        rabbit_event:reset_stats_timer(Connection,
                                       #stream_connection.stats_timer),
    ensure_stats_timer(Connection1).

ensure_stats_timer(Connection = #stream_connection{}) ->
    rabbit_event:ensure_stats_timer(Connection,
                                    #stream_connection.stats_timer, emit_stats).

in_vhost(_Pid, undefined) ->
    true;
in_vhost(Pid, VHost) ->
    case info(Pid, [vhost]) of
        [{vhost, VHost}] ->
            true;
        _ ->
            false
    end.

consumers_info(Pid, InfoItems) ->
    case InfoItems -- ?CONSUMER_INFO_ITEMS of
        [] ->
            gen_server2:call(Pid, {consumers_info, InfoItems});
        UnknownItems ->
            throw({bad_argument, UnknownItems})
    end.

consumers_infos(Items,
                #stream_connection_state{consumers = Consumers}) ->
    [[{Item, consumer_i(Item, Consumer)} || Item <- Items]
     || Consumer <- maps:values(Consumers)].

consumer_i(subscription_id, #consumer{subscription_id = SubId}) ->
    SubId;
consumer_i(credits, #consumer{credit = Credits}) ->
    Credits;
consumer_i(messages, #consumer{counters = Counters}) ->
    messages_consumed(Counters);
consumer_i(offset, #consumer{counters = Counters}) ->
    consumer_offset(Counters);
consumer_i(connection_pid, _) ->
    self();
consumer_i(stream, #consumer{stream = S}) ->
    S.

publishers_info(Pid, InfoItems) ->
    case InfoItems -- ?PUBLISHER_INFO_ITEMS of
        [] ->
            gen_server2:call(Pid, {publishers_info, InfoItems});
        UnknownItems ->
            throw({bad_argument, UnknownItems})
    end.

publishers_infos(Items,
                 #stream_connection{publishers = Publishers}) ->
    [[{Item, publisher_i(Item, Publisher)} || Item <- Items]
     || Publisher <- maps:values(Publishers)].

publisher_i(stream, #publisher{stream = S}) ->
    S;
publisher_i(connection_pid, _) ->
    self();
publisher_i(publisher_id, #publisher{publisher_id = Id}) ->
    Id;
publisher_i(reference, #publisher{reference = undefined}) ->
    <<"">>;
publisher_i(reference, #publisher{reference = Ref}) ->
    Ref;
publisher_i(messages_published,
            #publisher{message_counters = Counters}) ->
    messages_published(Counters);
publisher_i(messages_confirmed,
            #publisher{message_counters = Counters}) ->
    messages_confirmed(Counters);
publisher_i(messages_errored,
            #publisher{message_counters = Counters}) ->
    messages_errored(Counters).

info(Pid, InfoItems) ->
    case InfoItems -- ?INFO_ITEMS of
        [] ->
            gen_server2:call(Pid, {info, InfoItems});
        UnknownItems ->
            throw({bad_argument, UnknownItems})
    end.

infos(Items, Connection, State) ->
    [{Item, i(Item, Connection, State)} || Item <- Items].

i(pid, _, _) ->
    self();
i(node, _, _) ->
    node();
i(SockStat,
  #stream_connection{socket = Sock, send_file_oct = Counter}, _)
    when SockStat =:= send_oct -> % Number of bytes sent from the socket.
    case rabbit_net:getstat(Sock, [SockStat]) of
        {ok, [{_, N}]} when is_number(N) ->
            N + atomics:get(Counter, 1);
        _ ->
            0 + atomics:get(Counter, 1)
    end;
i(SockStat, #stream_connection{socket = Sock}, _)
    when SockStat =:= recv_oct; % Number of bytes received by the socket.
         SockStat =:= recv_cnt; % Number of packets received by the socket.
         SockStat =:= send_cnt; % Number of packets sent from the socket.
         SockStat
         =:= send_pend -> % Number of bytes waiting to be sent by the socket.
    case rabbit_net:getstat(Sock, [SockStat]) of
        {ok, [{_, N}]} when is_number(N) ->
            N;
        _ ->
            0
    end;
i(reductions, _, _) ->
    {reductions, Reductions} = erlang:process_info(self(), reductions),
    Reductions;
i(garbage_collection, _, _) ->
    rabbit_misc:get_gc_info(self());
i(state, Connection, ConnectionState) ->
    i(connection_state, Connection, ConnectionState);
i(timeout, Connection, ConnectionState) ->
    i(heartbeat, Connection, ConnectionState);
i(name, Connection, ConnectionState) ->
    i(conn_name, Connection, ConnectionState);
i(conn_name, #stream_connection{name = Name}, _) ->
    Name;
i(port, #stream_connection{port = Port}, _) ->
    Port;
i(peer_port, #stream_connection{peer_port = PeerPort}, _) ->
    PeerPort;
i(host, #stream_connection{host = Host}, _) ->
    Host;
i(peer_host, #stream_connection{peer_host = PeerHost}, _) ->
    PeerHost;
i(ssl, _, _) ->
    false;
i(peer_cert_subject, _, _) ->
    '';
i(peer_cert_issuer, _, _) ->
    '';
i(peer_cert_validity, _, _) ->
    '';
i(ssl_protocol, _, _) ->
    '';
i(ssl_key_exchange, _, _) ->
    '';
i(ssl_cipher, _, _) ->
    '';
i(ssl_hash, _, _) ->
    '';
i(channels, _, _) ->
    0;
i(protocol, _, _) ->
    <<"stream">>;
i(user_who_performed_action, Connection, ConnectionState) ->
    i(user, Connection, ConnectionState);
i(user, #stream_connection{user = U}, _) ->
    U#user.username;
i(vhost, #stream_connection{virtual_host = VirtualHost}, _) ->
    VirtualHost;
i(subscriptions, _,
  #stream_connection_state{consumers = Consumers}) ->
    maps:size(Consumers);
i(connection_state, _Connection,
  #stream_connection_state{blocked = true}) ->
    blocked;
i(connection_state, _Connection,
  #stream_connection_state{blocked = false}) ->
    running;
i(auth_mechanism, #stream_connection{auth_mechanism = none}, _) ->
    none;
i(auth_mechanism, #stream_connection{auth_mechanism = {Name, _Mod}},
  _) ->
    Name;
i(heartbeat, #stream_connection{heartbeat = Heartbeat}, _) ->
    Heartbeat;
i(frame_max, #stream_connection{frame_max = FrameMax}, _) ->
    FrameMax;
i(channel_max, _, _) ->
    0;
i(client_properties, #stream_connection{client_properties = CP}, _) ->
    rabbit_misc:to_amqp_table(CP);
i(connected_at, #stream_connection{connected_at = T}, _) ->
    T;
i(Item, #stream_connection{}, _) ->
    throw({bad_argument, Item}).
