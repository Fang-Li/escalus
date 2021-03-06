-module(escalus_fresh).
-export([story/3,
         story_with_client_list/3,
         story_with_config/3,
         create_users/2,
         freshen_specs/2,
         freshen_spec/2,
         create_fresh_user/2]).
-export([start/1,
         stop/1,
         clean/0]).

-type user_res() :: {atom(), integer()}.
-type config() :: escalus:config().

%% @doc
%% Run story with fresh users (non-breaking API).
%% The genererated fresh usernames will consist of the predefined {username, U} value
%% prepended to a unique, per-story suffix.
%% {username, <<"alice">>} -> {username, <<"alice32.632506">>}
-spec story(config(), [user_res()], fun()) -> any().
story(Config, UserSpecs, StoryFun) ->
    escalus:story(create_users(Config, UserSpecs), UserSpecs, StoryFun).

%% @doc
%% See escalus_story:story/3 for the difference between
%% story/3 and story_with_client_list/3.
-spec story_with_client_list(config(), [user_res()], fun()) -> any().
story_with_client_list(Config, UserSpecs, StoryFun) ->
    escalus_story:story_with_client_list(create_users(Config, UserSpecs), UserSpecs, StoryFun).

%% @doc
%% Run story with fresh users AND fresh config passed as first argument
%% If within a story there are references to the top-level Config object,
%% discrepancies may arise when querying this config object for user data,
%% as it will differ from the fresh config actually used by the story.
%% The story arguments can be changed from
%%
%% fresh_story(C,[..],fun(Alice, Bob) ->
%% to
%% fresh_story_with_config(C,[..],fun(FreshConfig, Alice, Bob) ->
%%
%% and any queries rewritten to use FreshConfig within this scope
-spec story_with_config(config(), [user_res()], fun()) -> any().
story_with_config(Config, UserSpecs, StoryFun) ->
    FreshConfig = create_users(Config, UserSpecs),
    escalus_story:story_with_client_list(FreshConfig, UserSpecs,
                                         fun(Args) -> apply(StoryFun, [FreshConfig | Args]) end).

%% @doc
%% Create fresh users for lower-level testing (NOT escalus:stories)
%% The users are created and the config updated with their fresh usernames.
%% The side effect is the creation of XMPP users on a server.
-spec create_users(config(), [user_res()]) -> config().
create_users(Config, UserSpecs) ->
    Suffix = fresh_suffix(),
    FreshSpecs = freshen_specs(Config, UserSpecs, Suffix),
    FreshConfig = escalus_users:create_users(Config, FreshSpecs),
    %% The line below is not needed if we don't want to support cleaning
    ets:insert(nasty_global_table(), {Suffix, FreshConfig}),
    FreshConfig.

%% @doc
%% freshen_spec/2 and freshen_specs/2
%% Creates a fresh spec without creating XMPP users on a server.
%% It is useful when testing some lower level parts of the protocol
%% i.e. some stream features. It is side-effect free.
-spec freshen_specs(config(), [user_res()]) -> [escalus_users:user_spec()].
freshen_specs(Config, UserSpecs) ->
    Suffix = fresh_suffix(),
    lists:map(fun({UserName, Spec}) -> Spec end,
              freshen_specs(Config, UserSpecs, Suffix)).

-spec freshen_spec(config(), escalus_users:user_name() | user_res()) -> escalus_users:user_spec().
freshen_spec(Config, {UserName, Res} = UserSpec) ->
    [FreshSpec] = freshen_specs(Config, [{UserName, 1}]),
    FreshSpec;
freshen_spec(Config, UserName) ->
    freshen_spec(Config, {UserName, 1}).


-spec freshen_specs(config(), [user_res()], binary()) -> [escalus_users:named_user()].
freshen_specs(Config, UserSpecs, Suffix) ->
    FreshSpecs = fresh_specs(Config, UserSpecs, Suffix),
    case length(FreshSpecs) == length(UserSpecs) of
        false ->
            error("failed to get required users");
        true ->
            FreshSpecs
    end.

%% @doc
%% Creates a fresh user along with XMPP user on a server.
-spec create_fresh_user(config(), user_res() | atom()) -> escalus_users:user_spec().
create_fresh_user(Config, {UserName, _Resource} = UserSpec) ->
    Config2 = create_users(Config, [UserSpec]),
    escalus_users:get_userspec(Config2, UserName);
create_fresh_user(Config, UserName) when is_atom(UserName) ->
    create_fresh_user(Config, {UserName, 1}).


%%% Stateful API
%%% Required if we expect to be able to clean up autogenerated users.
start(_Config) -> ensure_table_present(nasty_global_table()).
stop(_) -> nasty_global_table() ! bye.
clean() ->
    true = lists:all(fun(A) -> A == ok end,
                     pmap(fun delete_users/1,
                          ets:tab2list(nasty_global_table()))),
    ets:delete_all_objects(nasty_global_table()),
    ok.

%%% Internals
nasty_global_table() -> escalus_fresh_db.

delete_users({_Suffix, Conf}) ->
    Plist = proplists:get_value(escalus_users, Conf),
    escalus_users:delete_users(Conf, Plist),
    ok.

ensure_table_present(T) ->
    RunDB = fun() -> ets:new(T, [named_table, public]),
                      receive bye -> ok end end,
    case ets:info(T) of
        undefined ->
            P = spawn(RunDB),
            erlang:register(T, P);
        _nasty_table_is_there_well_run_with_it -> ok
    end.

fresh_specs(Config, TestedUsers, StorySuffix) ->
    AllSpecs = escalus_config:get_config(escalus_users, Config),
    [ make_fresh_username(Spec, StorySuffix)
      || Spec <- select(TestedUsers, AllSpecs) ].

make_fresh_username({N, UserConfig}, Suffix) ->
    {username, OldName} = proplists:lookup(username, UserConfig),
    NewName = << OldName/binary, Suffix/binary >>,
    {N, lists:keyreplace(username, 1, UserConfig, {username, NewName})}.

select(UserResources, FullSpecs) ->
    Fst = fun({A, _}) -> A end,
    UserNames = lists:map(Fst, UserResources),
    lists:filter(fun({Name, _}) -> lists:member(Name, UserNames) end,
                 FullSpecs).

fresh_suffix() ->
    {_, S, US} = erlang:now(),
    L = lists:flatten([integer_to_list(S rem 100), ".", integer_to_list(US)]),
    list_to_binary(L).


%%
pmap(F, L) when is_function(F, 1), is_list(L) ->
    TaskId = {make_ref(), self()},
    [spawn(worker(TaskId, F, El)) || El <- tag(L)],
    collect(TaskId, length(L), []).
tag(L) -> lists:zip(lists:seq(1, length(L)), L).
untag(L) -> [ Val || {_Ord, Val} <- lists:sort(L) ].
reply(Ord, {Ref, Pid}, Val) -> Pid ! {Ref, {Ord, Val}}.
worker(TaskId, Fun, {Ord, Item}) -> fun() -> reply(Ord, TaskId, catch(Fun(Item))) end.
collect(_TaskId, 0, Acc) -> untag(Acc);
collect({Ref, _} = TaskId, N, Acc) ->
    receive {Ref, Val} -> collect(TaskId, N-1, [Val|Acc])
    after 5000 -> error({partial_results, Acc})
    end.
