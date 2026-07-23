%%%-------------------------------------------------------------------
%% @doc Dynamic supervisor for per-match game session processes.
%%
%% Each match runs in its own stw_game gen_server, started on demand by
%% the lobby via start_game/2. Sessions are temporary: if one crashes it
%% is not restarted (the match is simply gone), matching the semantics of
%% ephemeral game rooms.
%% @end
%%%-------------------------------------------------------------------
-module(stw_game_sup).

-behaviour(supervisor).

-export([start_link/0, start_game/2]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Start a new game session for RoomCode with the given options map.
-spec start_game(binary(), map()) -> {ok, pid()}.
start_game(RoomCode, Opts) ->
    supervisor:start_child(?SERVER, [RoomCode, Opts]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 10,
                 period => 10},
    ChildSpec = #{id => stw_game,
                  start => {stw_game, start_link, []},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [stw_game]},
    {ok, {SupFlags, [ChildSpec]}}.
