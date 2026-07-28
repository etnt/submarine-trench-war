%%%-------------------------------------------------------------------
%% @doc stw application entry point.
%%
%% Starts the Cowboy HTTP listener that serves the static client, the
%% WebSocket endpoint, and the health/metrics endpoints, then starts the
%% top-level supervisor. When TLS is configured (see config/sys.config)
%% a second HTTPS listener is started so browsers can connect over
%% `wss://`; otherwise terminate TLS at a reverse proxy in front of the
%% plain HTTP listener.
%% @end
%%%-------------------------------------------------------------------
-module(stw_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Dispatch = dispatch(),
    Port = application:get_env(stw, http_port, 8080),
    {ok, _} = cowboy:start_clear(
        stw_http_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    logger:info("stw listening on http://0.0.0.0:~p", [Port]),
    maybe_start_tls(Dispatch),
    stw_sup:start_link().

stop(_State) ->
    ok = cowboy:stop_listener(stw_http_listener),
    _ = cowboy:stop_listener(stw_https_listener),
    ok.

%% --- internal ---------------------------------------------------------

dispatch() ->
    cowboy_router:compile([
        {'_', [
            {"/ws", stw_ws_handler, #{}},
            {"/health", stw_health_handler, #{mode => health}},
            {"/metrics", stw_health_handler, #{mode => metrics}},
            {"/", cowboy_static, {priv_file, stw, "index.html"}},
            {"/[...]", cowboy_static, {priv_dir, stw, ""}}
        ]}
    ]).

%% Start an HTTPS listener when `{tls, [...]}` is present in app env with
%% at least certfile + keyfile. Missing/partial config is a no-op so the
%% plain HTTP listener still serves (e.g. behind a TLS-terminating proxy).
maybe_start_tls(Dispatch) ->
    case application:get_env(stw, tls, undefined) of
        undefined ->
            ok;
        TlsOpts when is_list(TlsOpts) ->
            HttpsPort = proplists:get_value(https_port, TlsOpts, 8443),
            CertFile = proplists:get_value(certfile, TlsOpts),
            KeyFile = proplists:get_value(keyfile, TlsOpts),
            case CertFile =/= undefined andalso KeyFile =/= undefined of
                false ->
                    logger:warning(
                        "stw tls config present but missing certfile/keyfile; "
                        "skipping HTTPS listener"),
                    ok;
                true ->
                    SocketOpts = [{port, HttpsPort},
                                  {certfile, CertFile},
                                  {keyfile, KeyFile}]
                        ++ [{cacertfile, C}
                            || C <- [proplists:get_value(cacertfile, TlsOpts)],
                               C =/= undefined],
                    {ok, _} = cowboy:start_tls(
                        stw_https_listener,
                        SocketOpts,
                        #{env => #{dispatch => Dispatch}}
                    ),
                    logger:info("stw listening on https://0.0.0.0:~p", [HttpsPort]),
                    ok
            end
    end.
