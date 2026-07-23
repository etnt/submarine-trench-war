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

init(Req, State) ->
    Opts = #{idle_timeout => ?IDLE_TIMEOUT},
    {cowboy_websocket, Req, State, Opts}.

websocket_init(State) ->
    %% seq is a monotonic per-connection sequence number for server->client
    %% messages (see PROTOCOL.md).
    {[], State#{seq => 0}}.

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
websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info(_Info, State) ->
    {[], State}.

%% --- internal ---------------------------------------------------------

handle_message(#{<<"type">> := <<"ping">>} = Msg, State) ->
    Seq = maps:get(<<"seq">>, Msg, null),
    Payload = #{<<"reply_to">> => Seq,
                <<"server_time">> => now_ms()},
    reply(envelope(<<"pong">>, Payload), State);
handle_message(#{<<"type">> := Type} = Msg, State) ->
    %% Echo unknown messages back so the client can confirm round-trip.
    Payload = #{<<"echo_type">> => Type,
                <<"echo_payload">> => maps:get(<<"payload">>, Msg, #{})},
    reply(envelope(<<"echo">>, Payload), State);
handle_message(_Other, State) ->
    reply(error_msg(null, <<"missing_type">>,
                    <<"Message envelope requires a 'type' field.">>), State).

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
