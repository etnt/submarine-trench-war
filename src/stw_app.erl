%%%-------------------------------------------------------------------
%% @doc stw application entry point.
%%
%% Starts the Cowboy HTTP listener that serves the static client and
%% the WebSocket endpoint, then starts the top-level supervisor.
%% @end
%%%-------------------------------------------------------------------
-module(stw_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Port = application:get_env(stw, http_port, 8080),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws", stw_ws_handler, #{}},
            {"/", cowboy_static, {priv_file, stw, "index.html"}},
            {"/[...]", cowboy_static, {priv_dir, stw, ""}}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(
        stw_http_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    io:format("stw listening on http://localhost:~p~n", [Port]),
    stw_sup:start_link().

stop(_State) ->
    ok = cowboy:stop_listener(stw_http_listener),
    ok.
