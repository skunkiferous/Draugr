# shellcheck shell=bash
#
# lib/agents/default.sh - the answer for an agent whose layout nobody has measured.
#
# sbx offers ten agents. Draugr has taken the trouble to learn where two of them
# keep their memory; this file is what the other eight get, and it says so rather
# than guessing. Everything that does not depend on the agent - attaching, kits,
# dr-sync, dr-send, dr-data, the clone - works exactly the same for all of them.
#
# It is also the specification of the module interface. Every file in this
# directory defines all of these; tests/agents.bats fails if one does not.
#
#   dr_agent_mem_supported        0 when this agent's memory layout is known
#   dr_agent_mem_label            how to name the agent in a sentence
#   dr_agent_mem_dir <repo>       the directory holding memory inside the mound,
#                                 for reports. Its PARENT is what dr-mem creates
#                                 and copies into, so the two cannot drift apart
#   dr_agent_mem_survey           a directory to list when dr_agent_mem_dir is
#                                 missing, so a wrong guess is visible rather
#                                 than silent
#   dr_agent_mem_present <repo>   0 when the mound holds anything worth exporting
#   dr_agent_mem_list <repo>      "<sha256>  <name>" for everything carried,
#                                 named relative to the PACKED tree below
#   dr_agent_mem_pack <repo> <d>  assemble everything carried into mound dir <d>
#   dr_agent_mem_unpack <repo> <d>  put the contents of mound dir <d> back
#   dr_agent_mem_host_dir <repo>  this repo's memory in a HOST install of the
#                                 same agent, for `dr-mem import --from-host`.
#                                 Returns 1 when there is none
#   dr_agent_mem_host_hint <repo> where the line above looked, for the message
#                                 printed when it found nothing
#   dr_agent_mem_status_extra <repo>  extra `dr-mem status` sections for this
#                                 agent, heading included, or nothing at all
#   dr_agent_secret               the service name sbx stores this agent's
#                                 credentials under. Returns 1 when unknown
#   dr_agent_model_supported      0 when this agent can be pointed at another
#                                 endpoint, i.e. when DRAUGR_MODEL can work
#   dr_agent_model_env <url> <model> <fast>
#                                 the KEY=value lines to export into the attach
#                                 rcfile, one a line, for those three values
#
# pack, unpack and list are the contract that matters, and they are three views
# of one thing: the PACKED TREE. Whatever pack writes is what the store holds,
# what unpack reads back, and what list names - so the three cannot disagree
# about a layout without a test noticing. dr-mem owns the transfer either way,
# and never learns what is inside.
#
# A module may define more than this - see lib/agents/codex.sh, which has a
# feature flag and a database to worry about that Claude Code does not.

# The one that matters: dr-mem checks this before it moves anything, because
# copying a directory into a place the agent never reads is worse than refusing.
# It looks like it worked, and the agent has still forgotten everything.
dr_agent_mem_supported() { return 1; }

# $DRAUGR_AGENT is the honest label here - we know its name and nothing else.
dr_agent_mem_label() { printf '%s' "${DRAUGR_AGENT:-the agent}"; }

# Both path answers are "no idea", spelled as a failure rather than as a path
# that would then be created, filled and never read.
dr_agent_mem_dir()    { return 1; }
dr_agent_mem_survey() { printf '%s' "$DR_MOUND_HOME"; }

# Nothing to find, nothing to list, and nothing to move. These exist so that a
# caller which reached here despite dr_agent_mem_supported gets an empty answer
# rather than "command not found" three frames deep.
dr_agent_mem_present() { return 1; }
dr_agent_mem_list()    { return 0; }
dr_agent_mem_pack()    { return 1; }
dr_agent_mem_unpack()  { return 1; }

# Nothing agent-specific to add to a status report we cannot produce anyway.
dr_agent_mem_status_extra() { return 0; }

# sbx knows a fixed set of credential services, and which one an agent wants is
# not derivable from its name - "droid" and "cursor" are their own, "opencode"
# is none of them. Unknown here means dr-doctor says nothing rather than
# recommending a secret that does not exist.
dr_agent_secret() { return 1; }

# Which variables an agent reads to find its endpoint is per-agent and not
# derivable from its name, so an unmeasured agent says so. This one matters more
# than the others: an agent that ignored DRAUGR_MODEL would keep talking to its
# cloud while you believed the work was staying local, so dr_model_check turns a
# failure here into a refusal rather than a shrug.
dr_agent_model_supported() { return 1; }
dr_agent_model_env()       { return 1; }

# No host-side layout either, so --from-host has nothing to offer, and the hint
# says which of the two possible reasons it is: nothing there, or nobody looked.
dr_agent_mem_host_dir()  { return 1; }
dr_agent_mem_host_hint() {
    printf 'Draugr does not know where %s keeps memory on the host.' \
        "$(dr_agent_mem_label)"
}
