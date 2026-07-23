%%%-------------------------------------------------------------------
%% @doc Phase 0 WebSocket handler.
%%
%% Accepts JSON text frames using the protocol envelope defined in
%% plan/PROTOCOL.md. For now it only handles `ping` (replying with
%% `pong`) and echoes any other message back to the sender. This is a
%% scaffold that later phases replace with lobby/session routing.
%% @end
%%%-------------------------------------------------------------------
-module(stw_ws_handler).

-behaviour(cowboy_websocket).

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).

%% Exported for unit testing of pure message logic.
-export([decode/1]).

-define(IDLE_TIMEOUT, 60000).
%% Send a keepalive ping well within the idle timeout. Turns can take a long
%% time (players plan their moves), during which the client sends nothing; the
%% browser auto-replies to these pings at the protocol level (even in a
%% backgrounded tab), which resets Cowboy's idle timer and keeps the socket up.
-define(PING_INTERVAL, 25000).

init(Req, State) ->
    Opts = #{idle_timeout => ?IDLE_TIMEOUT},
    {cowboy_websocket, Req, State, Opts}.

websocket_init(State) ->
    %% Per-connection state:
    %%   seq          - monotonic sequence for server->client messages
    %%   player_id    - assigned on `hello`
    %%   token        - session token (for reconnect)
    %%   display_name - chosen name
    %%   game         - pid of the joined game (or undefined)
    %%   room_code    - current room code (or undefined)
    schedule_ping(),
    {[], State#{seq => 0,
                player_id => undefined,
                token => undefined,
                display_name => undefined,
                game => undefined,
                room_code => undefined}}.

websocket_handle({text, Data}, State) ->
    case decode(Data) of
        {ok, Msg} ->
            handle_message(Msg, State);
        {error, _Reason} ->
            reply(error_msg(null, <<"bad_json">>,
                            <<"Message was not valid JSON.">>), State)
    end;
websocket_handle({ping, _}, State) ->
    %% Respond to protocol-level WebSocket pings automatically.
    {[], State};
websocket_handle({pong, _}, State) ->
    %% Client's reply to our keepalive ping; nothing to do.
    {[], State};
websocket_handle(_Frame, State) ->
    {[], State}.

%% Game/lobby processes deliver server->client messages as {push, Type,
%% Payload}; we stamp the envelope (seq/ts) here and send it as a frame.
websocket_info(keepalive, State) ->
    %% Emit a keepalive ping and schedule the next one.
    schedule_ping(),
    {[{ping, <<>>}], State};
websocket_info({push, Type, Payload}, State) ->
    reply(envelope(Type, Payload), State);
websocket_info(_Info, State) ->
    {[], State}.

schedule_ping() ->
    erlang:send_after(?PING_INTERVAL, self(), keepalive).

%% --- internal ---------------------------------------------------------

handle_message(#{<<"type">> := Type} = Msg, State) ->
    Payload = maps:get(<<"payload">>, Msg, #{}),
    Seq = maps:get(<<"seq">>, Msg, null),
    dispatch(Type, Payload, Seq, State);
handle_message(_Other, State) ->
    reply(error_msg(null, <<"missing_type">>,
                    <<"Message envelope requires a 'type' field.">>), State).

%% hello: mint or resume identity, and reconnect into a room if present.
dispatch(<<"hello">>, P, _Seq, State) ->
    Token = maps:get(<<"session_token">>, P, undefined),
    Name = maps:get(<<"display_name">>, P, <<"Captain">>),
    {PlayerId, Token1, RoomCode} = stw_lobby:hello(Token, Name),
    State1 = State#{player_id => PlayerId,
                    token => Token1,
                    display_name => Name},
    State2 = resume_room(RoomCode, PlayerId, State1),
    Welcome = #{<<"protocol_version">> => 1,
                <<"player_id">> => PlayerId,
                <<"session_token">> => Token1,
                <<"server_time">> => now_ms()},
    reply(envelope(<<"welcome">>, Welcome), State2);

dispatch(<<"ping">>, _P, Seq, State) ->
    Payload = #{<<"reply_to">> => Seq, <<"server_time">> => now_ms()},
    reply(envelope(<<"pong">>, Payload), State);

dispatch(<<"create_game">>, P, Seq, State) ->
    case maps:get(player_id, State) of
        undefined ->
            reply(error_msg(Seq, <<"no_identity">>,
                            <<"Send hello before creating a game.">>), State);
        PlayerId ->
            Opts = #{max_players => maps:get(<<"max_players">>, P, 4),
                     map_id => maps:get(<<"map_id">>, P, <<"trench_alpha">>)},
            {ok, RoomCode, GamePid} =
                stw_lobby:create_game(maps:get(token, State), Opts),
            {ok, IsHost} = stw_game:join(GamePid, PlayerId,
                                         maps:get(display_name, State), self()),
            State1 = State#{game => GamePid, room_code => RoomCode},
            reply(game_joined(RoomCode, PlayerId, IsHost), State1)
    end;

dispatch(<<"join_game">>, P, Seq, State) ->
    case maps:get(player_id, State) of
        undefined ->
            reply(error_msg(Seq, <<"no_identity">>,
                            <<"Send hello before joining a game.">>), State);
        PlayerId ->
            RoomCode = normalize_code(maps:get(<<"room_code">>, P, <<>>)),
            case stw_lobby:join_room(maps:get(token, State), RoomCode) of
                {ok, GamePid} ->
                    join_existing(GamePid, RoomCode, PlayerId, Seq, State);
                {error, room_not_found} ->
                    reply(error_msg(Seq, <<"room_not_found">>,
                                    <<"No room with that code.">>), State)
            end
    end;

dispatch(<<"set_ready">>, P, Seq, State) ->
    with_game(Seq, State, fun(GamePid, PlayerId) ->
        Ready = maps:get(<<"ready">>, P, false),
        stw_game:set_ready(GamePid, PlayerId, Ready),
        {[], State}
    end);

dispatch(<<"start_game">>, _P, Seq, State) ->
    with_game(Seq, State, fun(GamePid, PlayerId) ->
        case stw_game:start_game(GamePid, PlayerId) of
            ok ->
                {[], State};
            {error, not_host} ->
                reply(error_msg(Seq, <<"not_host">>,
                                <<"Only the host can start the game.">>), State)
        end
    end);

dispatch(<<"leave_game">>, _P, Seq, State) ->
    with_game(Seq, State, fun(GamePid, PlayerId) ->
        stw_game:leave(GamePid, PlayerId),
        {[], State#{game => undefined, room_code => undefined}}
    end);

dispatch(<<"program_registers">>, P, Seq, State) ->
    with_game(Seq, State, fun(GamePid, PlayerId) ->
        Cards = maps:get(<<"registers">>, P, []),
        case stw_game:program_registers(GamePid, PlayerId, Cards) of
            ok ->
                {[], State};
            {error, Code} ->
                reply(error_msg(Seq, program_error(Code),
                                <<"Invalid program.">>), State)
        end
    end);

dispatch(<<"lock_registers">>, _P, Seq, State) ->
    with_game(Seq, State, fun(GamePid, PlayerId) ->
        case stw_game:lock_registers(GamePid, PlayerId) of
            ok ->
                {[], State};
            {error, Code} ->
                reply(error_msg(Seq, program_error(Code),
                                <<"Cannot lock registers.">>), State)
        end
    end);

dispatch(_Type, _P, Seq, State) ->
    reply(error_msg(Seq, <<"unknown_type">>,
                    <<"Unrecognized message type.">>), State).

%% Map a stw_game program/lock error to a protocol error code.
program_error(invalid_register) -> <<"invalid_register">>;
program_error(not_in_game) -> <<"not_in_game">>;
program_error(no_program) -> <<"invalid_register">>;
program_error(_) -> <<"internal_error">>.

%% Run Fun with the current game pid + player id, or return not_in_game.
with_game(Seq, State, Fun) ->
    case maps:get(game, State) of
        undefined ->
            reply(error_msg(Seq, <<"not_in_game">>,
                            <<"You are not in a game.">>), State);
        GamePid ->
            Fun(GamePid, maps:get(player_id, State))
    end.

join_existing(GamePid, RoomCode, PlayerId, Seq, State) ->
    case stw_game:join(GamePid, PlayerId,
                       maps:get(display_name, State), self()) of
        {ok, IsHost} ->
            State1 = State#{game => GamePid, room_code => RoomCode},
            reply(game_joined(RoomCode, PlayerId, IsHost), State1);
        {error, room_full} ->
            reply(error_msg(Seq, <<"room_full">>,
                            <<"That room is full.">>), State)
    end.

%% On hello-resume, re-bind this connection to the game it left off in.
resume_room(undefined, _PlayerId, State) ->
    State#{game => undefined, room_code => undefined};
resume_room(RoomCode, PlayerId, State) ->
    case stw_lobby:lookup_room(RoomCode) of
        {ok, GamePid} ->
            stw_game:reconnect(GamePid, PlayerId, self()),
            State#{game => GamePid, room_code => RoomCode};
        error ->
            State#{game => undefined, room_code => undefined}
    end.

game_joined(RoomCode, PlayerId, IsHost) ->
    envelope(<<"game_joined">>, #{<<"room_code">> => RoomCode,
                                  <<"player_id">> => PlayerId,
                                  <<"is_host">> => IsHost}).

normalize_code(Code) when is_binary(Code) ->
    string:uppercase(string:trim(Code));
normalize_code(_) ->
    <<>>.

reply(Envelope, State0) ->
    {Json, State1} = encode(Envelope, State0),
    {[{text, Json}], State1}.

%% Build a server->client envelope, stamping the next seq at encode time.
envelope(Type, Payload) ->
    #{<<"type">> => Type, <<"payload">> => Payload}.

error_msg(ReplyTo, Code, Message) ->
    envelope(<<"error">>, #{<<"reply_to">> => ReplyTo,
                            <<"code">> => Code,
                            <<"message">> => Message}).

encode(Envelope0, #{seq := Seq} = State) ->
    Envelope = Envelope0#{<<"seq">> => Seq, <<"ts">> => now_ms()},
    {iolist_to_binary(json:encode(Envelope)), State#{seq => Seq + 1}}.

decode(Data) ->
    try
        {ok, json:decode(Data)}
    catch
        _:Reason -> {error, Reason}
    end.

now_ms() ->
    erlang:system_time(millisecond).
