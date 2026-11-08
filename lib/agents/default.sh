# shellcheck shell=bash
#
# lib/agents/default.sh: the module for an agent whose file layout nobody tested.
#
# sbx has ten agents. Draugr learned where two of them keep their memory. The
# other eight get this file. It says that it does not know, and it does not
# guess. All functions that do not depend on the agent work the same for all
# agents: attach, kits, dr-sync, dr-send, dr-data, and the clone.
#
# This file is also the specification of the module interface. Each file in
# this directory defines all of these functions. If a file does not,
# tests/agents.bats fails.
#
#   dr_agent_mem_supported        0 when the memory layout of this agent is known
#   dr_agent_mem_label            the name of the agent, for use in a sentence
#   dr_agent_mem_dir <repo>       the directory in the mound that holds memory,
#                                 for reports. dr-mem creates its PARENT and
#                                 copies into it, so the two cannot drift apart
#   dr_agent_mem_survey           a directory to list when dr_agent_mem_dir is
#                                 missing, so that a wrong guess is visible
#   dr_agent_mem_present <repo>   0 when the mound holds data to export
#   dr_agent_mem_list <repo>      "<sha256>  <name>" for each copied file, with
#                                 names relative to the PACKED tree below
#   dr_agent_mem_pack <repo> <d>  collect all copied files into mound dir <d>
#   dr_agent_mem_unpack <repo> <d>  put the contents of mound dir <d> back
#   dr_agent_mem_host_dir <repo>  the memory of this repo in a HOST install of
#                                 the same agent, for `dr-mem import --from-host`.
#                                 Returns 1 when there is none
#   dr_agent_mem_host_hint <repo> where the line above looked, for the message
#                                 when it found nothing
#   dr_agent_mem_status_extra <repo>  extra `dr-mem status` sections for this
#                                 agent, with a heading, or nothing
#   dr_agent_secret               the service name under which sbx stores the
#                                 credentials of this agent. 1 when unknown
#   dr_agent_signin               how to get that secret, one hint on each line.
#                                 It is for each agent, because it differs: sbx
#                                 runs the OAuth flow for some services and
#                                 refuses for others
#   dr_agent_plugin_supported     0 when this agent has a plugin library that
#                                 Draugr can build. If not, dr-plugin refuses
#   dr_agent_plugin_cache_var     the variable that sends the plugin CLI of the
#                                 agent to a library that is not its default.
#                                 Without it, Draugr cannot build a seed
#   dr_agent_plugin_seed_var      the variable that gives a session a READ-ONLY
#                                 library, for the advice that dr-plugin prints
#                                 when the configuration is not complete
#   dr_agent_plugin_cli <verb> [arg...]
#                                 the argv for one plugin operation, one word on
#                                 each line. Verbs: market-add, market-remove,
#                                 market-update, install, update, uninstall, list
#   dr_agent_model_supported      0 when this agent can use a different endpoint,
#                                 that is, when DRAUGR_MODEL can work
#   dr_agent_model_env <url> <model> <fast>
#                                 the KEY=value lines to export into the attach
#                                 rcfile, one on each line, for those three values
#
# pack, unpack, and list are the important part of the contract. They are three
# views of one thing: the PACKED TREE. What pack writes is what the store holds,
# what unpack reads, and what list names. If the three disagree about a
# layout, a test finds it. dr-mem does the transfer in both directions, and
# never learns what is in it.
#
# A module can define more functions than these. See lib/agents/codex.sh. It
# has a feature flag and a database, and Claude Code has neither.

# The most important function. dr-mem calls it before it moves anything. A copy
# of a directory to a place that the agent never reads is worse than a refusal.
# It looks as if it worked, but the agent still forgot everything.
dr_agent_mem_supported() { return 1; }

# $DRAUGR_AGENT is the correct label here. Draugr knows its name and nothing else.
dr_agent_mem_label() { printf '%s' "${DRAUGR_AGENT:-the agent}"; }

# Both path answers are "unknown". They are a failure, not a path. The code
# creates and fills a path that it gets, and the agent never reads it.
dr_agent_mem_dir()    { return 1; }
dr_agent_mem_survey() { printf '%s' "$DR_MOUND_HOME"; }

# Nothing to find, nothing to list, and nothing to move. These functions exist
# for a caller that gets here in spite of dr_agent_mem_supported. That caller
# then gets an empty answer, not "command not found" three calls deep.
dr_agent_mem_present() { return 1; }
dr_agent_mem_list()    { return 0; }
dr_agent_mem_pack()    { return 1; }
dr_agent_mem_unpack()  { return 1; }

# There is nothing to add for this agent. Draugr cannot make its status report.
dr_agent_mem_status_extra() { return 0; }

# sbx knows a fixed set of credential services. The name of an agent does not
# tell which service it uses. "droid" and "cursor" have their own services, and
# "opencode" has none of them. Unknown here means that dr-doctor says nothing.
# It does not recommend a secret that does not exist.
dr_agent_secret() { return 1; }

# dr_agent_signin: how to set that secret, one hint on each line.
#
# The two general hints. For an agent that nobody tested, Draugr can say no
# more. With no arguments, `sbx secret set` asks for the scope and the service.
# Thus it is the one form that cannot be wrong here.
#
# It is a different question from dr_agent_secret, because the ANSWER differs
# more than the service name. sbx runs the OAuth flow for some services. For
# others, it refuses, and tells you to sign in inside the sandbox.
dr_agent_signin() {
    printf 'Sign in:  sbx secret set -g %s\n' "$1"
    printf 'Or let sbx prompt for scope and service:  sbx secret set\n'
}

# Plugins, and why an agent that nobody tested gets nothing and not a guess.
#
# Draugr cannot find the format of a plugin library from the name of an agent.
# The format is a directory layout, a CLI with its own verbs, and an
# environment variable that changes the location of both. The format of Claude
# Code was tested and is in claude.sh. All other agents refuse. Thus dr-plugin
# says "not measured", and does not build a directory that the agent never reads.
#
# This is more important here than for memory. If dr-mem copies to the wrong
# place, the agent loses what it learned. If dr-plugin builds the wrong format,
# it puts third-party CODE in a directory that each mound on the machine mounts.
dr_agent_plugin_supported() { return 1; }
dr_agent_plugin_cache_var() { return 1; }
dr_agent_plugin_seed_var()  { return 1; }
dr_agent_plugin_cli()       { return 1; }

# Each agent reads different variables to find its endpoint, and its name does
# not tell which. Thus an agent that nobody tested says so. This one is more
# important than the others. An agent that ignores DRAUGR_MODEL continues to
# use its cloud, while you think that the work stays local. Thus dr_model_check
# changes a failure here into a refusal.
dr_agent_model_supported() { return 1; }
dr_agent_model_env()       { return 1; }

# There is also no known layout on the host. Thus --from-host has nothing to
# give. The hint tells which of the two reasons it is: nothing is there, or
# nobody looked.
dr_agent_mem_host_dir()  { return 1; }
dr_agent_mem_host_hint() {
    printf 'Draugr does not know where %s keeps memory on the host.' \
        "$(dr_agent_mem_label)"
}
