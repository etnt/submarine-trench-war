%%%-------------------------------------------------------------------
%% @doc stw top-level supervisor.
%%
%% For Phase 0 this supervisor has no children. Game-session and lobby
%% processes will be added in later phases.
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
    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.
