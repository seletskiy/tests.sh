#!/bin/bash

set -euo pipefail

# Public API Functions {{{

# @description Make all functions from tests.sh available without 'tests:'
# prefix. Prefix can be also user defined, like 't:'.
#
# @arg $1 string Custom prefix for namespace functions.
tests:import-namespace() {
    local prefix="${1:-}"

    tests:debug "! importing namespace 'tests:'" \
        $(sed -re"s/.+/ into '&'/" <<< $prefix)

    builtin eval $(
        declare -F |
        grep -F -- '-f tests:' |
        cut -d: -f2 |
        sed -re's/.*/'$prefix'&() { tests:& "${@}"; };/'
    )
}

# @description Returns temporary directory for current test session.
#
# It can be used as a workspace for the testcase.
#
# @example
#   ls $(tests:get-tmp-dir)
#
# @stdout Path to temp dir, e.g, /tmp/tests.XXXX
tests:get-tmp-dir() {
    if [ -z "$_tests_dir" ]; then
        tests:debug "test session not initialized"
        _tests_interrupt
    fi

    echo "$_tests_dir"
}

# @description Asserts, that first string arg is equals to second.
#
# @example
#   tests:assert-equals 1 2 # fails
#
# @arg $1 string Expected string.
# @arg $2 string Actual value.
tests:assert-equals() {
    local expected="$1"
    local actual="$2"

    _tests_make_assertion "$expected" "$actual" \
        "two strings not equals" \
        ">>> $expected$" \
        "<<< $actual$"

    _tests_inc_asserts_count
}

# @description Asserts, that last evaluated command's stdout contains given
# string.
#
# @example
#   tests:eval echo 123
#   tests:assert-stdout 123
#
# @arg $1 string Expected stdout.
tests:assert-stdout() {
    local expected="$1"
    shift

    tests:assert-stdout-re "$(_tests_quote_re <<< "$expected")"
}

# @description Asserts, that last evaluated command's stderr contains given
# string.
#
# @example
#   tests:eval echo 123 '1>&2' # note quoting
#   tests:assert-stderr 123
#
# @arg $1 string Expected stderr.
tests:assert-stderr() {
    local expected="$1"
    shift

    tests:assert-stderr-re "$(_tests_quote_re <<< "$expected")"
}

# @description Compares, that last evaluated command output (stdout, stderr) or
# file contents matches regexp.
#
# @example
#   tests:eval echo aaa
#   tests:match-re stdout a.a
#   echo $? # 0
#   tests:match-re stdout a.b
#   echo $? # 1
#
# @arg $1 'stdout'|'stderr'|filename If 'stdout' or 'stderr' is used, use
# last command's stream as actual value. If filename is specified, then use
# contents of specified filename as actual contents.
#
# @arg $2 regexp Regexp to match, same as in grep.
tests:match-re() {
    local target="$1"
    local regexp="$2"
    shift 2

    if [ -f $target ]; then
        file=$target
    elif [ "$target" = "stdout" ]; then
        file=$_tests_stdout
    else
        file=$_tests_stderr
    fi

    if [ -z "$regexp" ]; then
        if [ -s $file ]; then
            echo 1
        else
            echo 0
        fi
    elif grep -qP "$regexp" $file; then
        echo 0
    else
        echo $?
    fi > $_tests_exitcode
}

# @description Same as 'tests:match-re', but abort testing if comparison
# failed.
#
# @example
#   tests:eval echo aaa
#   tests:assert-re stdout a.a
#   tests:assert-re stdout a.b # test fails there
#
# @see tests:match-re
tests:assert-re() {
    local target="$1"
    local regexp="$2"
    shift 2

    tests:match-re "$target" "$regexp"

    local result=$(cat $_tests_exitcode)

    _tests_make_assertion $result 0 \
        "regexp does not match" \
        ">>> ${regexp:-<empty regexp>}" \
        "<<< contents of ${target}:\n\
            $(_tests_indent "$target" < $file)"

    _tests_inc_asserts_count
}

# @description Asserts, that there are no diff on the last command output
# (stderr or stdout), or on string or on specified file with specified string
# or file.
#
# @example
#   tests:eval echo -e '1\n2'
#   tests:assert-no-diff stdout "$(echo -e '1\n2')" # note quotes
#   tests:assert-no-diff stdout "$(echo -e '1\n3')" # test will fail
#
# @arg $1 string|filename Expected value.
# @arg $2 'stdout'|'stderr'|string|filename Actual value.
# @arg $@ any Additional arguments for diff.
tests:assert-no-diff() {
    if [ -s /dev/stdin ]; then
        local expected_target=/dev/stdin
    else
        local expected_target="$1"
        shift
    fi

    local actual_target="$1"
    shift
    local options="-u $@"

    if [ -e "$expected_target" ]; then
        expected_content="$(cat $expected_target)"
    else
        expected_content="$expected_target"
    fi

    if [ -e "$actual_target" ]; then
        actual_content="$(cat $actual_target)"
    elif [ "$actual_target" = "stdout" ]; then
        actual_content="$(cat $_tests_stdout)"
    elif [ "$actual_target" = "stderr" ]; then
        actual_content="$(cat $_tests_stderr)"
    else
        actual_content="$actual_target"
    fi

    local diff
    local result=0
    if diff=$(diff `echo $options` \
            <(echo -e "$expected_content") \
            <(echo -e "$actual_content")); then
        result=0
    else
        result=$?
    fi

    _tests_make_assertion $result 0 \
        "no diff\n\
            $(_tests_indent 'diff' <<< "$diff")"

    _tests_inc_asserts_count
}

# @description Returns file containing stdout of last command.
#
# @example
#   tests:eval echo 123
#   cat $(tests:get-stdout-file) # will echo 123
#
# @stdout Filename containing stdout.
tests:get-stdout-file() {
    echo $_tests_stdout
}

# @description Returns file containing stderr of last command.
#
# @example
#   tests:eval echo 123 '1>&2' # note quotes
#   cat $(tests:get-stderr) # will echo 123
#
# @stdout Filename containing stderr.
tests:get-stderr-file() {
    echo $_tests_stderr
}

# @description Same as 'tests:assert-diff', but ignore changes whose lines are
# all blank.
#
# @example
#   tests:eval echo -e '1\n2'
#   tests:assert-no-diff-blank stdout "$(echo -e '1\n2')" # note quotes
#   tests:assert-no-diff-blank stdout "$(echo -e '1\n\n2')" # test will pass
#
# @see tests:diff
tests:assert-no-diff-blank() {
    tests:assert-no-diff "$1" "$2" "-B"
}

# @description Same as shell 'test' function, but asserts, that exit code is
# zero.
#
# @example
#   tests:assert-test 1 -eq 1
#   tests:assert-test 1 -eq 2 # test will fail
#
# @arg $@ Arguments for 'test' function.
tests:assert-test() {
    local args="$@"

    tests:debug "test $args"
    local result
    if test "$@"; then
        result=0
    else
        result=$?
    fi

    if [ $result -ne 0 ]; then
        touch "$_tests_dir/.failed"
        tests:debug "test $args: failed"
        _tests_interrupt
    fi

    _tests_inc_asserts_count
}

# @description Put specified contents into temporary file with given name.
#
# @example
#   tests:put-string xxx "lala"
#
#   tests:assert-equals xxx "lala" # test will pass
#
# @arg $1 filename Temporary file name.
# @arg $2 string Contents to put.
tests:put-string() {
    local file="$1"
    local content="$2"

    tests:put "$file" <<< "$content"
}

# @description Put stdin into temporary file with given name.
#
# @example
#   tests:put xxx <<EOF
#   1
#   2
#   3
#   EOF
#
#   tests:assert-no-diff xxx "$(echo -e '1\n2\n3')" # test will pass
#
# @arg $1 filename Temporary file name.
tests:put() {
    local file="$_tests_dir/$1"

    local stderr
    if ! stderr=$(cat 2>&1 > $file); then
        tests:debug "error writing file:"
        _tests_indent 'error' <<< "$stderr"
        _tests_interrupt
    fi

    tests:debug "wrote the file $file with content:"
    _tests_indent 'file' < $file

}

# @description Asserts that stdout of last evaluated command matches given
# regexp.
#
# @example
#   tests:eval echo 123
#
#   tests:assert-stdout-re 1.3 # will pass
#
# @arg $1 regexp Regexp, same as in grep.
tests:assert-stdout-re() {
    tests:assert-re stdout "$@"
}

# @description Asserts as 'tests:assert-stdout-re', but stderr used instead
# of stdout.
#
# @example
#   tests:eval echo 123 '1>&2' # note quotes
#
#   tests:assert-stderr-re 1.3 # will pass
#
# @arg $1 regexp Regexp, same as in grep.
tests:assert-stderr-re() {
    tests:assert-re stderr "$@"
}

# @description Asserts that last evaluated command exit status is zero.
#
# @example
#   tests:eval true
#   tests:assert-success
#
# @noargs
tests:assert-success() {
    tests:assert-exitcode 0
}

# @description Asserts that last evaluated command exit status is not zero.
# Basically, alias for `test:not tests:assert-success`.
#
# @example
#   tests:eval false
#   tests:assert-fail
#
# @noargs
tests:assert-fail() {
    tests:not tests:assert-success
}

# @description Asserts that exit code of last evaluated command equals to
# specified value.
#
# @example
#   tests:eval false
#   tests:assert-exitcode 1
#
# @arg $1 int Expected exit code.
tests:assert-exitcode() {
    local actual=$(cat $_tests_exitcode)
    local expected=$1
    shift

    _tests_make_assertion "$expected" "$actual" \
        "exit code expectation failed" \
        "actual exit code = $actual" \
        "expected exit code $_tests_last_assert_operation $expected"

    _tests_inc_asserts_count
}

# @description Negates passed assertion.
#
# @example
#   tests:eval false
#   tests:assert-fail
#   tests:not tests:assert-success
#
#   tests:eval true
#   tests:assert-success
#   tests:not tests:assert-fail
#
# @arg $1 int Expected exit code.
tests:not() {
    local old_exitcode=$?

    _tests_assert_operation="!="
    _tests_last_assert_operation="!="

    "${@}"
    _tests_assert_operation="="
}

# @description Same as tests:debug(), but colorize output
# for better vizibility.
#
# @arg $@ any String to output.
tests:describe() {
    tests:debug "@@ \e[7;49;34m" ${@} "\e[0m"
}

# @description Print specified string in the debug log.
#
# @example
#   tests:debug "hello from debug" # will shown only in verbose mode
#
# @arg $@ any String to echo.
tests:debug() {
    if [ $_tests_verbose -lt 1 ]; then
        return
    fi

    if [ "$_tests_dir" ]; then
        echo -e "# $_tests_dir: $@"
    else
        echo -e "### $@"
    fi >&2
}

# @description Changes working directory to specified directory.
#
# @arg $1 directory Directory to change to.
tests:cd() {
    local dir=$1
    tests:debug "\$ cd $1"
    builtin cd $1
}

# @description Evaluates specified string via shell 'eval'.
#
# @example
#   tests:eval echo 123 "# i'm comment"
#   tests:eval echo 123 \# i\'m comment
#   tests:eval echo 567 '1>&2' # redirect to stderr
#   tests:eval echo 567 1>\&2' # same
#
# @arg $@ string String to evaluate.
tests:eval() {
    local input=/dev/stdin

    if [ -s "$input" ]; then
        tests:debug "$ (stdin) > $@"
    else
        input=/dev/null

        tests:debug "$ $@"
    fi

    {
        if _tests_eval_and_capture_output "${@}"; then
            echo 0 > $_tests_exitcode
        else
            echo $? > $_tests_exitcode
        fi < <(tee /dev/stderr < $input)
    } 2>&1 | _tests_indent 'stdin'

    if [ -s $_tests_stdout ]; then
        tests:debug "evaluation stdout:"
        _tests_indent 'stdout' < $_tests_stdout
    else
        tests:debug "evaluation stdout is empty"
    fi

    if [ -s $_tests_stderr ]; then
        tests:debug "evaluation stderr:"
        _tests_indent 'stderr' < $_tests_stderr
    else
        tests:debug "evaluation stderr is empty"
    fi
}

# @description Eval specified command and assert, that it has zero exitcode.
#
# @example
#   tests:esnure true # will pass
#   tests:esnure false # will fail
#
# @arg $@ any Command to evaluate.
tests:ensure() {
    tests:eval "$@"
    tests:assert-success
}

# @description Creates temporary directory.
#
# @arg $@ any Same as for mkdir command.
tests:make-tmp-dir() {
    # prepend to any non-flag argument $_tests_dir prefix

    tests:debug "making directories in $_tests_dir: mkdir ${@}"

    local stderr
    if ! stderr=$(
        /bin/mkdir \
            $(sed -re "s#(^|\\s)([^-])#\\1$_tests_dir/\\2#g" <<< "${@}")); then
        tests:debug "error making directories ${@}:"
        _tests_indent 'error' <<< "$stderr"
        _tests_interrupt
    fi
}

# @description Changes working directory to the specified temporary directory,
# previously created by 'tests:mkdir'.
#
# @arg $1 string Directory name.
tests:cd-tmp-dir() {
    tests:cd $_tests_dir/$1
}

# @description Runs any command in background, this is very useful if you test
# some running service.
#
# Processes which are ran by 'tests:background' will be killed on cleanup
# state, and if test failed, stderr and stdout of all background processes will
# be printed.
#
# @arg $@ string Command to start.
#
# @stdout Unique identifier of running backout process.
tests:run-background() {
    local cmd="$@"

    local identifier=$(date +'%s.%N' | md5sum | head -c 6)
    local dir="$_tests_dir/.bg/$identifier/"


    tests:debug "starting background task #$identifier"
    tests:debug "# '$cmd'"

    /bin/mkdir -p "$dir"

    tests:debug "working directory: $dir"

    echo "$identifier" > "$dir/id"
    echo "$cmd" > "$dir/cmd"

    touch "$dir/stdout"
    touch "$dir/stderr"
    touch "$dir/pid"

    builtin eval "( { $cmd; } >$dir/stdout 2>$dir/stderr )" \
        {0..255}\<\&- {0..255}\>\&- \&

    local bg_pid=$!

    echo "$bg_pid" > "$dir/pid"
    tests:debug "background process started, pid = $bg_pid"

    echo "$identifier"
}

# @description Returns pid of specified background process.
#
# @arg $1 string Process ID, returned from 'tests:run-background'.
#
# @stdout Pid of background process.
tests:get-background-pid() {
    cat "$_tests_dir/.bg/$1/pid"
}

# @description Returns stdout of specified background process.
#
# @arg $1 string Process ID, returned from 'tests:run-background'.
#
# @stdout Stdout from background process.
tests:get-background-stdout() {
    echo "$_tests_dir/.bg/$1/stdout"
}

# @description Returns stderr of specified background process.
#
# @arg $1 string Process ID, returned from 'tests:run-background'.
#
# @stdout Stderr from background process.
tests:background-stderr() {
    echo "$_tests_dir/.bg/$1/stderr"
}

# @description Stops background process with 'kill -9'.
#
# @arg $1 string Process ID, returned from 'tests:run-background'.
tests:stop-background() {
    local id="$1"
    local pid=$(cat $_tests_dir/.bg/$id/pid)

    kill -TERM "$pid" 2>/dev/null

    tests:debug "background task #$id stopped"
    rm -rf $_tests_dir/.bg/$id/
}

# @description Waits, until specified file will be changed or timeout passed
# after executing specified command.
#
# @arg $1 string Command to evaluate.
# @arg $2 filename Filename to wait changes in.
# @arg $3 int Interval of time to check changes after.
# @arg $4 int Timeout in seconds.
tests:wait-file-changes() {
    local cmd="$1"
    local file="$2"
    local sleep_interval="$3"
    local sleep_max="$4"

    local stat_initial=$(stat $file)
    local sleep_iter=0
    local sleep_iter_max=$(bc <<< "$sleep_max/$sleep_interval")

    tests:debug "% waiting file changes after executing cmd: $cmd"
    tests:eval $cmd

    while true; do
        sleep_iter=$(($sleep_iter+1))

        local stat_actual=$(stat $file)
        if [[ "$stat_initial" == "$stat_actual" ]]; then
            if [[ $sleep_iter -ne $sleep_iter_max ]]; then
                tests:eval sleep $sleep_interval
                continue
            fi

            return 1
        fi

        return 0
    done
}

# @description Sets verbosity of testcase output.
#
# @arg $1 int Verbosity.
tests:set-verbose() {
    _tests_verbose=$1
}

# @description Copy specified file or directory from the testcases
# dir to the temporary test directory.
#
# @arg $@ any Same args, as for cp commmand.
tests:clone() {
    local args=(dummy)
    local last_arg=""

    while [ $# -gt 0 ]; do
        if [ "$last_arg" ]; then
            args+=($_tests_base_dir/$last_arg)
        fi

        last_arg=""

        if grep -q '^-' <<< "$1"; then
            args=($args $1)
        else
            last_arg=$1
        fi

        shift
    done

    local files="${args[@]:1}"
    local dest="$_tests_dir/$last_arg"

    tests:debug "\$ cp $files $dest"

    local stderr
    if ! stderr=$(/bin/cp "$files" "$dest" 2>&1); then
        tests:debug "error copying: cp $files $dest:"
        _tests_indent 'error' <<< "$stderr"
        _tests_interrupt
    fi

}

# @description Copy specified file from testcases to the temporary test
# directory and then source it.
#
# @arg $1 filename Filename to copy and source.
# @arg $2 filename Destination under test dir (not required).
# $exitcode >0 If source failed
tests:involve() {
    local source="$1"
    local basename="$(basename "$1")"
    local destination="${2:-.}"

    if [ -d $destination ]; then
        destination=$destination/$(basename $source)
    fi

    tests:clone "$source" "$destination"

    tests:require $destination
}

# @description Source file with debug.
#
# @arg $1 filename Filename to source.
# $exitcode >0 If source failed
tests:require() {
    local file="$1"

    tests:debug "{BEGIN} source $file"
    tests:debug "\$ source $file"

    trap "tests:debug '{ERROR} in $file'" EXIT

    builtin source "$file"

    trap - EXIT

    tests:debug "{END} source $file"
}
# }}}

# Internal Code {{{

# Internal global state {{{
#
# Do not use this variables directly.

# Current test session.
_tests_dir=""

# Verbosity level.
_tests_verbose=0

# Assertions counter.
_tests_asserts=0

# File with last stdout.
_tests_stdout=""

# File with last stderr.
_tests_stderr=""

# File with stderr and stout from eval
_tests_out=""

# File with last exitcode.
_tests_exitcode=""

# Current working directory for test suite.
_tests_base_dir=""

# Operation used in assertions (= or !=)
_tests_assert_operation="="

# Last used assert operation.
_tests_last_assert_operation="="

# }}}

_tests_eval() {
    local cmd=()
    for i in "$@"; do
        case $i in
            '`'*)  cmd+=($i) ;;
            *'`')  cmd+=($i) ;;
            *'>'*) cmd+=($i) ;;
            *'<'*) cmd+=($i) ;;
            *'&')  cmd+=($i) ;;
            '|')   cmd+=($i) ;;
            *)     cmd+=(\'"$i"\')
        esac
    done

    # drop positional arguments
    set --

    builtin eval "${cmd[@]}"
}

_tests_indent() {
    local prefix="${1:-}"
    if [ $_tests_verbose -lt 3 ]; then
        prefix=""
    fi

    if [ "$prefix" ]; then
        sed -e "s/^/($prefix) /"
    else
        cat
    fi | sed -e 's/^/    /' -e '1i\ ' -e '$a\ '
}

_tests_quote_re() {
    sed -r 's/[.*+[()?$^]|]/\\\0/g'
}

_tests_quote_cmd() {
    local cmd=()
    for i in "$@"; do
        if grep -q "[' \"\$]" <<< "$i"; then
            cmd+=($(sed -r -e "s/['\"\$]/\\&/" -e "s/.*/'&'/" <<< "$i"))
        else
            cmd+=($i)
        fi
    done

    echo "${cmd[@]}"
}

_tests_get_testcases() {
    local directory="$1"
    local mask="$2"
    (
        shopt -s globstar nullglob
        echo $directory/$mask
    )
}

_tests_run_all() {
    local testcases_dir="$1"
    local testcase_setup="$2"
    local see_subdirs=$3

    local filemask="*.test.sh"
    if $see_subdirs; then
        filemask="**/*.test.sh"
    fi

    local testcases=($(_tests_get_testcases "$testcases_dir" "$filemask"))
    if [ ! -v testcases ]; then
        echo no testcases found.

        exit 1
    fi


    local verbose=$_tests_verbose
    if [ $verbose -lt 1 ]; then
        _tests_verbose=4
    fi

    local testsuite_dir=$(readlink -f "$_tests_base_dir/$testcases_dir")
    echo running test suite at: $testsuite_dir
    echo
    if [ $verbose -eq 0 ]; then
        echo -ne '  '
    fi

    local success=0
    local assertions_count=0
    for file in "${testcases[@]}"; do
        if [ $verbose -eq 0 ]; then
            local stdout="`mktemp -t stdout.XXXX`"
            local pwd="$(pwd)"

            _tests_asserts=0

            local result
            if _tests_run_one "$file" "$testcase_setup" &> $stdout; then
                result=0
            else
                result=$?
            fi

            builtin cd "$pwd"
            if [ $result -eq 0 ]; then
                echo -n .
                success=$((success+1))
                rm -f $stdout
            else
                echo -n F
                echo
                echo
                cat $stdout
                rm -f $stdout
                _tests_set_last "$file"
                exit $result
            fi
        else
            local result
            if _tests_run_one "$file" "$testcase_setup"; then
                result=0
            else
                result=$?
            fi
            if [ $result -ne 0 ]; then
                _tests_set_last "$file"
                exit $result
            fi

            success=$((success+1))
        fi

        assertions_count=$(($assertions_count+$_tests_asserts))
    done

    _tests_rm_last

    echo
    echo
    echo ---
    echo "$success tests ($assertions_count assertions) done successfully!"
}

_tests_run_one() {
    local testcase="$1"
    local testcase_setup="$2"

    local testcase_file="$_tests_base_dir/$testcase"

    if ! test -e $testcase; then
        echo "testcase '$testcase' not found"
        return 1
    fi

    tests:debug "TESTCASE $testcase"

    _tests_init

    if [ ! -s $_tests_dir/.asserts ]; then
        echo 0 > $_tests_dir/.asserts
    fi

    local result
    if _tests_run_raw "$testcase_file" "$testcase_setup"; then
        result=0
    else
        result=$?
    fi

    _tests_asserts=$(cat $_tests_dir/.asserts)

    if [[ $result -ne 0 && ! -f "$_tests_dir/.failed" ]]; then
        tests:debug "test exited with non-zero exit code"
        tests:debug "exit code = $result"
        touch "$_tests_dir/.failed"
    fi

    _tests_cleanup

    if [ $result -ne 0 ]; then
        tests:debug "TESTCASE FAILED $testcase"
        return 1
    else
        tests:debug "TESTCASE PASSED $testcase"$'\n'
        return 0
    fi
}

_tests_run_raw() {
    local testcase_file="$1"
    local testcase_setup="$2"
    (
        PATH="$_tests_dir/bin:$PATH"

        builtin cd $_tests_dir

        if [ -n "$testcase_setup" ]; then
            tests:debug "{BEGIN} SETUP"

            if ! tests:involve "$testcase_setup"; then
                exit 1
            fi
            tests:debug "{END} SETUP"
        fi

        builtin source "$testcase_file"
    ) 2>&1 | _tests_indent
}

_tests_get_last() {
    cat .last-testcase
}

_tests_set_last() {
    local testcase=$1
    echo "$testcase" > $_tests_base_dir/.last-testcase
}

_tests_rm_last() {
    rm -f .last-testcase
}

_tests_init() {
    _tests_dir="$(mktemp -t -d tests.XXXX)"

    /bin/mkdir $_tests_dir/bin

    _tests_stderr="$_tests_dir/.stderr"
    _tests_stdout="$_tests_dir/.stdout"
    _tests_exitcode="$_tests_dir/.exitcode"
    _tests_out="$_tests_dir/.eval"

    touch $_tests_stderr
    touch $_tests_stdout
    touch $_tests_exitcode
    touch $_tests_out

    tests:debug "{BEGIN} TEST SESSION"
}

_tests_cleanup() {
    tests:debug "{END} TEST SESSION"

    local failed=""
    if test -e "$_tests_dir/.failed"; then
        failed=1
    fi

    for bg_dir in $_tests_dir/.bg/*; do
        if ! test -d $bg_dir; then
            continue
        fi

        local bg_id=$(cat $bg_dir/id)

        if [ $failed ]; then
            local bg_cmd=$(cat $bg_dir/cmd)
            local bg_stdout=$(cat $bg_dir/stdout)
            local bg_stderr=$(cat $bg_dir/stderr)


            tests:debug "background task #$bg_id cmd:"
            tests:debug "# $bg_cmd"

            if [[ "$bg_stdout" == "" ]]; then
                tests:debug "background task #$bg_id stdout is empty"
            else
                tests:debug "background task #$bg_id stdout:"
                _tests_indent 'stdout' <<< "$bg_stdout"
            fi

            if [[ "$bg_stderr" == "" ]]; then
                tests:debug "background task #$bg_id stderr is empty"
            else
                tests:debug "background task #$bg_id stderr:"
                _tests_indent 'stderr' <<< "$bg_stderr"
            fi
        fi

        tests:stop-background $bg_id
    done

    rm -rf "$_tests_dir"

    _tests_dir=""
}

_tests_interrupt() {
    exit 88
}

_tests_make_assertion() {
    local result
    if test "$1" $_tests_assert_operation "$2"; then
        result=0
    else
        result=$?
    fi

    shift 2

    if [ $result -gt 0 ]; then
        touch "$_tests_dir/.failed"
        tests:debug "expectation failed: $1"
        shift
        while [ $# -gt 0 ]; do
            tests:debug "$1"

            shift
        done

        _tests_interrupt
    fi
}

_tests_inc_asserts_count() {
    local count=$(cat $_tests_dir/.asserts)
    echo $(($count+1)) > $_tests_dir/.asserts
}

_tests_eval_and_capture_output() {
    (
        set +euo pipefail

        case $_tests_verbose in
            0|1)
                _tests_eval "${@}" \
                    > $_tests_stdout \
                    2> $_tests_stderr
                ;;
            2)
                # Process substitution will not work there, because
                # it will be executed asyncronously.
                #
                # Consider: true > >(sleep 1; echo hello)
                #
                # `true` will exit no matter running sleep, and hello will
                # be shown only after 1 second pass.
                { _tests_eval "${@}" \
                    | tee $_tests_stdout 1>&3; exit ${PIPESTATUS[0]}; } \
                    2> $_tests_stderr 3>&1
                ;;
            *)
                # We need to return exitcode of _tests_eval, not tee, so
                # we need to use PIPESTATUS[0] which will be equal to exitcode
                # of _tests_eval.
                #
                # It's required, because -o pipefail is not set here.
                { { _tests_eval "${@}" \
                    | tee $_tests_stdout 1>&3; exit ${PIPESTATUS[0]}; } 2>&1 \
                    | tee $_tests_stderr 1>&2; exit ${PIPESTATUS[0]}; } 3>&1
                ;;
        esac
    ) > $_tests_out 2>&1
}

_tests_print_docs() {
    parser='# start of awk code {{{

    BEGIN {
        if (! style) {
            style = "github"
        }

        styles["github", "h1", "from"] = ".*"
        styles["github", "h1", "to"] = "## &"

        styles["github", "h2", "from"] = ".*"
        styles["github", "h2", "to"] = "### &"

        styles["github", "h3", "from"] = ".*"
        styles["github", "h3", "to"] = "#### &"

        styles["github", "code", "from"] = ".*"
        styles["github", "code", "to"] = "```&"

        styles["github", "/code", "to"] = "```"

        styles["github", "argN", "from"] = "^(\\$[0-9]) (\\S+)"
        styles["github", "argN", "to"] = "**\\1** (\\2):"

        styles["github", "arg@", "from"] = "^\\$@ (\\S+)"
        styles["github", "arg@", "to"] = "**...** (\\1):"

        styles["github", "li", "from"] = ".*"
        styles["github", "li", "to"] = "* &"

        styles["github", "i", "from"] = ".*"
        styles["github", "i", "to"] = "_&_"

        styles["github", "anchor", "from"] = ".*"
        styles["github", "anchor", "to"] = "[&](#&)"

        styles["github", "exitcode", "from"] = "([0-9]) (.*)"
        styles["github", "exitcode", "to"] = "**\\1**: \\2"
    }

    function render(type, text) {
        return gensub( \
            styles[style, type, "from"],
            styles[style, type, "to"],
            "g",
            text \
        )
    }

    /^# @description/ {
        in_description = 1
        in_example = 0

        has_example = 0
        has_args = 0
        has_exitcode = 0
        has_stdout = 0

        docblock = ""
    }

    in_description {
        if (/^[^#]|^# @[^d]/) {
            in_description = 0
        } else {
            sub(/^# @description /, "")
            sub(/^# /, "")
            sub(/^#$/, "")

            if ($0) {
                $0 = $0 "\n"
            }

            docblock = docblock $0
        }
    }

    in_example {
        if (! /^#[ ]{3}/) {
            in_example = 0

            docblock = docblock "\n" render("/code") "\n"
        } else {
            sub(/^#[ ]{3}/, "")

            docblock = docblock "\n" $0
        }
    }

    /^# @example/ {
        in_example = 1

        docblock = docblock "\n" render("h3", "Example")
        docblock = docblock "\n\n" render("code", "bash")
    }

    /^# @arg/ {
        if (!has_args) {
            has_args = 1

            docblock = docblock "\n" render("h2", "Arguments") "\n\n"
        }

        sub(/^# @arg /, "")

        $0 = render("argN", $0)
        $0 = render("arg@", $0)

        docblock = docblock render("li", $0) "\n"
    }

    /^# @noargs/ {
        docblock = docblock "\n" render("i", "Function has no arguments.") "\n"
    }

    /^# @exitcode/ {
        if (!has_exitcode) {
            has_exitcode = 1

            docblock = docblock "\n" render("h2", "Exit codes") "\n\n"
        }

        sub(/^# @exitcode /, "")

        $0 = render("exitcode", $0)

        docblock = docblock render("li", $0) "\n"
    }

    /^# @see/ {
        sub(/# @see /, "")

        $0 = render("anchor", $0)
        $0 = render("li", $0)

        docblock = docblock "\n" render("h3", "See also") "\n\n" $0 "\n"
    }

    /^# @stdout/ {
        has_stdout = 1

        sub(/^# @stdout /, "")

        docblock = docblock "\n" render("h2", "Output on stdout")
        docblock = docblock "\n\n" render("li", $0) "\n"
    }

    /^tests:[a-zA-Z0-9_-]+\(\)/ && docblock != "" {
        print render("h1", $1) "\n\n" docblock

        docblock = ""
    }

    # }}} end of awk code'

    awk "$parser" "$(basename $0)"
}


_tests_show_usage() {
    cat <<EOF
tests.sh --- simple test library for testing commands.

tests.sh expected to find files named *.test.sh in current directory, and
they are treated as testcases.

Usage:
    tests.sh -h
    tests.sh [-v] [-d <dir>] [-s <path>] -A [-a]
    tests.sh [-v] [-d <dir>] [-s <path>] -O [<name>]
    tests.sh -i

Options:
    -h | --help  Show this help.
    -A           Run all testcases in current directory.
    -a           Run all testcases in subdirectories of current directory.
    -O <name>    Run specified testcase only. If no testcase specified, last
                 failed testcase will be ran.
    -s <path>    Run specified setup file before running every testcase.
    -d <dir>     Change directory to specified before running testcases.
                 [default: current working directory].
    -v           Verbosity. Flag can be specified several times.
    -i           Pretty-prints documentation for public API in markdown format.
EOF
}


__main__() {
    _tests_base_dir=$(pwd)

    local testcases_dir="."
    local testcases_setup=""
    local see_subdirs=false

    while getopts ":his:d:va" arg "${@}"; do
        case $arg in
            d)
                testcases_dir="$OPTARG"
                ;;
            v)
                _tests_verbose=$(($_tests_verbose+1))
                ;;
            i)
                _tests_print_docs
                ;;
            h)
                _tests_show_usage
                exit 1
                ;;
            a)
                see_subdirs=true
                ;;
            s)
                testcases_setup="$OPTARG"
                ;;
            ?)
                args+=("$OPTARG")
        esac
    done

    local OPTIND

    while getopts ":his:d:vaAO" arg "${@}"; do
        case $arg in
            A)
                _tests_run_all \
                    "$testcases_dir" "$testcases_setup" $see_subdirs

                exit $?
                ;;
            O)
                tests:set-verbose 4

                local filemask=${@:$OPTIND:1}
                if [ -z "$filemask" ]; then
                    local files=$(_tests_get_last)
                else
                    local files=($(eval echo \*$filemask\*.test.sh))
                fi

                for name in "${files[@]}"; do
                    if ! _tests_run_one "$name" "$testcases_setup"; then
                        exit 1
                    fi
                done

                exit $?
                ;;
            h)
                _tests_show_usage
                exit 1
                ;;
        esac
    done

    _tests_show_usage
    exit 1
}


if [ "$(basename $0)" == "tests.sh" ]; then
    __main__ "${@}"
fi
