%%%-------------------------------------------------------------------
%% @doc Health and metrics HTTP endpoints.
%%
%% Two plain (non-WebSocket) Cowboy handlers selected by the route's
%% `mode` option:
%%
%%   * `health`  -> GET /health  : liveness probe, returns 200 "ok".
%%   * `metrics` -> GET /metrics : JSON observability snapshot suitable
%%                                 for scraping (active games, players in
%%                                 rooms, tracked sessions, uptime).
%%
%% These are deliberately unauthenticated and side-effect free so load
%% balancers, container orchestrators, and simple monitors can poll them.
%% @end
%%%-------------------------------------------------------------------
-module(stw_health_handler).

-export([init/2]).

-ifdef(TEST).
-export([metrics/0]).
-endif.

init(Req, #{mode := health} = State) ->
    Req1 = cowboy_req:reply(
             200,
             #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
             <<"ok">>,
             Req),
    {ok, Req1, State};
init(Req, #{mode := metrics} = State) ->
    Body = iolist_to_binary(json:encode(metrics())),
    Req1 = cowboy_req:reply(
             200,
             #{<<"content-type">> => <<"application/json; charset=utf-8">>},
             Body,
             Req),
    {ok, Req1, State}.

%% Gather a snapshot, tolerating a lobby that is momentarily unavailable
%% (e.g. during startup) so the endpoint never crashes the request.
metrics() ->
    Base = #{<<"status">> => <<"ok">>,
             <<"uptime_ms">> => uptime_ms()},
    try stw_lobby:stats() of
        Stats when is_map(Stats) -> maps:merge(Base, Stats)
    catch
        _:_ ->
            Base#{<<"active_games">> => 0,
                  <<"players_in_rooms">> => 0,
                  <<"tracked_sessions">> => 0}
    end.

uptime_ms() ->
    {Total, _SinceLast} = erlang:statistics(wall_clock),
    Total.
