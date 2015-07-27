# Use git-annex's built-in bash completion
# This bash completion is generated by the option parser, so it covers all
# commands, all options, and will never go out of date!
_git-annex()
{
    local cmdline
    CMDLINE=(--bash-completion-index $COMP_CWORD)

    for arg in ${COMP_WORDS[@]}; do
        CMDLINE=(${CMDLINE[@]} --bash-completion-word $arg)
    done

    COMPREPLY=( $(git-annex "${CMDLINE[@]}") )
}

complete -o bashdefault -o default -o filenames -F _git-annex git-annex

# Called by git's bash completion script when completing "git annex"
_git_annex() {
    local cmdline
    CMDLINE=(--bash-completion-index $(($COMP_CWORD - 1)))

    local seen_git
    local seen_annex
    for arg in ${COMP_WORDS[@]}; do
        if [ "$arg" = git ] && [ -z "$seen_git" ]; then
		seen_git=1
		CMDLINE=(${CMDLINE[@]} --bash-completion-word git-annex)
	elif [ "$arg" = annex ] && [ -z "$seen_annex" ]; then
		seen_annex=1
	else
		CMDLINE=(${CMDLINE[@]} --bash-completion-word $arg)
	fi
    done

    COMPREPLY=( $(git-annex "${CMDLINE[@]}") )
}
