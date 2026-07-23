%%%-------------------------------------------------------------------
%% @doc stw top-level supervisor.
%%
%% Starts the dynamic game-session supervisor and the lobby. The game
%% supervisor must start first because the lobby spawns game sessions
%% through it.
%% @end
%%%-------------------------------------------------------------------
-module(stw_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 5,
                 period => 10},
    ChildSpecs = [
        #{id => stw_game_sup,
          start => {stw_game_sup, start_link, []},
          restart => permanent,
          shutdown => infinity,
          type => supervisor,
          modules => [stw_game_sup]},
        #{id => stw_lobby,
          start => {stw_lobby, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [stw_lobby]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
