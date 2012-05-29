
%% write your own $USER.spec to override the default profile
%% or set SYSTEST_PROFILE in the environment to override both choices

{logdir, "{{ tmpdir }}/logs"}.

{config, "{{ base_dir }}/resources/rabbit_nodes.config"}.
{config, "{{ base_dir }}/resources/simple_ha_cluster.config"}.

{alias, test, "{{ base_dir }}/test"}.
{suites, test, all}.

{include, "{{ base_dir }}/lib/rabbit/include"}.
{include, "{{ base_dir }}/lib/rabbit_common/include"}.
{include, "{{ base_dir }}/lib/amqp_client/include"}.
