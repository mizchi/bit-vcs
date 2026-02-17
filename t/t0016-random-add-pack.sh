#!/bin/bash
#
# Randomized operation log focused on add-index + pack compatibility.

source "$(dirname "$0")/test-lib-e2e.sh"

LCG_STATE=0
RAND_VALUE=0

lcg_next() {
    LCG_STATE=$(( (LCG_STATE * 1103515245 + 12345) & 0x7fffffff ))
}

rand_range() {
    local n="$1"
    if [ "$n" -le 0 ]; then
        RAND_VALUE=0
        return
    fi
    lcg_next
    RAND_VALUE=$(( LCG_STATE % n ))
}

gen_ops() {
    local seed="$1"
    local steps="$2"
    local max_branches="$3"
    local out="$4"

    LCG_STATE="$seed"

    declare -a branches
    declare -A next_id
    declare -A last_file
    declare -A commit_count

    branches=("main")
    next_id["main"]=0
    last_file["main"]=""
    commit_count["main"]=0

    local cur="main"
    local branch_seq=1

    echo "init" > "$out"

    local file="${cur}_${next_id[$cur]}_base.txt"
    next_id[$cur]=$((next_id[$cur] + 1))
    last_file[$cur]="$file"
    echo "commit-new $file seed${seed}_0" >> "$out"
    commit_count[$cur]=$((commit_count[$cur] + 1))

    local step=1
    while [ "$step" -le "$steps" ]; do
        local op
        rand_range 13
        op=$RAND_VALUE
        case "$op" in
            0)
                file="${cur}_${next_id[$cur]}.txt"
                next_id[$cur]=$((next_id[$cur] + 1))
                last_file[$cur]="$file"
                commit_count[$cur]=$((commit_count[$cur] + 1))
                echo "commit-new $file seed${seed}_${step}" >> "$out"
                ;;
            1)
                if [ -n "${last_file[$cur]}" ]; then
                    echo "commit-mod ${last_file[$cur]} seed${seed}_${step}" >> "$out"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    commit_count[$cur]=$((commit_count[$cur] + 1))
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            2)
                if [ -n "${last_file[$cur]}" ] && [ "${commit_count[$cur]}" -gt 0 ]; then
                    echo "commit-rm ${last_file[$cur]}" >> "$out"
                    last_file["$cur"]=""
                    commit_count[$cur]=$((commit_count[$cur] - 1))
                    if [ "${commit_count[$cur]}" -lt 0 ]; then
                        commit_count[$cur]=0
                    fi
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    commit_count[$cur]=$((commit_count[$cur] + 1))
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            3)
                if [ "${#branches[@]}" -lt "$max_branches" ]; then
                    local b="b${branch_seq}"
                    branch_seq=$((branch_seq + 1))
                    branches+=("$b")
                    next_id["$b"]=0
                    last_file["$b"]=""
                    commit_count["$b"]=0
                    echo "branch $b" >> "$out"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    commit_count[$cur]=$((commit_count[$cur] + 1))
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            4)
                if [ "${#branches[@]}" -gt 1 ]; then
                    local idx
                    rand_range "${#branches[@]}"
                    idx=$RAND_VALUE
                    local target="${branches[$idx]}"
                    if [ "$target" = "$cur" ]; then
                        idx=$(( (idx + 1) % ${#branches[@]} ))
                        target="${branches[$idx]}"
                    fi
                    echo "switch $target" >> "$out"
                    cur="$target"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    commit_count[$cur]=$((commit_count[$cur] + 1))
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            5)
                file="${cur}_${next_id[$cur]}_dot.txt"
                next_id[$cur]=$((next_id[$cur] + 1))
                last_file[$cur]="$file"
                commit_count[$cur]=$((commit_count[$cur] + 1))
                echo "add-dot $file seed${seed}_${step}" >> "$out"
                ;;
            6)
                file="${cur}_${next_id[$cur]}_all.txt"
                next_id[$cur]=$((next_id[$cur] + 1))
                last_file[$cur]="$file"
                commit_count[$cur]=$((commit_count[$cur] + 1))
                echo "add-all $file seed${seed}_${step}" >> "$out"
                ;;
            7)
                if [ -n "${last_file[$cur]}" ] && [ "${commit_count[$cur]}" -gt 0 ]; then
                    echo "add-all-rm ${last_file[$cur]}" >> "$out"
                    last_file["$cur"]=""
                    commit_count[$cur]=$((commit_count[$cur] - 1))
                    if [ "${commit_count[$cur]}" -lt 0 ]; then
                        commit_count[$cur]=0
                    fi
                else
                    file="${cur}_${next_id[$cur]}_all.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    commit_count[$cur]=$((commit_count[$cur] + 1))
                    echo "add-all $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            8)
                if [ -n "${last_file[$cur]}" ] && [ "${commit_count[$cur]}" -gt 0 ]; then
                    echo "add-refresh ${last_file[$cur]}" >> "$out"
                else
                    file="${cur}_${next_id[$cur]}_refresh.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    commit_count[$cur]=$((commit_count[$cur] + 1))
                    echo "add-dot $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            9)
                echo "status" >> "$out"
                ;;
            10)
                echo "pack-objects" >> "$out"
                ;;
            11)
                echo "index-pack" >> "$out"
                ;;
            12)
                echo "repack" >> "$out"
                ;;
            13)
                echo "gc" >> "$out"
                ;;
        esac
        step=$((step + 1))
    done
}

has_pack_file() {
    local path
    for path in .git/objects/pack/pack-*.pack; do
        if [ -f "$path" ]; then
            return 0
        fi
    done
    return 1
}

apply_ops() {
    local tool="$1"
    local repo="$2"
    local opfile="$3"

    local run_cmd
    if [ "$tool" = "git" ]; then
        run_cmd="git"
    else
        run_cmd="git_cmd"
    fi

    local base_date=1700000000
    local commit_seq=0

    mkdir -p "$repo"
    local old_dir
    old_dir=$(pwd)
    cd "$repo"

    while read -r op arg1 arg2; do
        case "$op" in
            init)
                $run_cmd init
                ;;
            branch)
                $run_cmd branch "$arg1"
                ;;
            switch)
                $run_cmd switch "$arg1"
                ;;
            commit-new)
                local ts=$((base_date + commit_seq))
                echo "$arg2" > "$arg1"
                $run_cmd add "$arg1"
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "commit $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            commit-mod)
                local ts=$((base_date + commit_seq))
                echo "$arg2" >> "$arg1"
                $run_cmd add "$arg1"
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "commit $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            commit-rm)
                local ts=$((base_date + commit_seq))
                $run_cmd rm "$arg1"
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "commit $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            add-dot)
                local ts=$((base_date + commit_seq))
                echo "$arg2" > "$arg1"
                $run_cmd add .
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "add-dot $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            add-all)
                local ts=$((base_date + commit_seq))
                echo "$arg2" > "$arg1"
                $run_cmd add -A
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "add-all $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            add-all-rm)
                local ts=$((base_date + commit_seq))
                $run_cmd rm "$arg1"
                $run_cmd add -A
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "add-all-rm $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            add-refresh)
                $run_cmd add --refresh "$arg1" >/dev/null
                ;;
            status)
                $run_cmd status --porcelain >/dev/null
                ;;
            repack)
                $run_cmd repack -a -d
                ;;
            pack-objects)
                if ! $run_cmd rev-parse --verify HEAD >/dev/null 2>&1; then
                    continue
                fi
                local pack_stem=".git/objects/pack/compat"
                $run_cmd rev-parse HEAD | $run_cmd pack-objects "$pack_stem" >/dev/null 2>&1 || true
                ;;
            index-pack)
                local pack_file
                pack_file=$(ls .git/objects/pack/*.pack 2>/dev/null | head -n 1 || true)
                if [ -n "$pack_file" ]; then
                    $run_cmd index-pack "$pack_file" >/dev/null 2>&1 || true
                fi
                ;;
            gc)
                $run_cmd gc
                ;;
            *)
                echo "unknown op: $op" >&2
                return 1
                ;;
        esac
    done < "$opfile"

    cd "$old_dir"
}

compare_repos() {
    local repo_git="$1"
    local repo_bit="$2"

    git -C "$repo_git" fsck --strict
    git -C "$repo_bit" fsck --strict

    local heads_git
    local heads_bit
    heads_git=$(git -C "$repo_git" for-each-ref --format='%(refname:short)' refs/heads | sort)
    heads_bit=$(git -C "$repo_bit" for-each-ref --format='%(refname:short)' refs/heads | sort)
    [ "$heads_git" = "$heads_bit" ]

    local b
    for b in $heads_git; do
        local tree_git
        local tree_bit
        tree_git=$(git -C "$repo_git" rev-parse "$b^{tree}")
        tree_bit=$(git -C "$repo_bit" rev-parse "$b^{tree}")
        [ "$tree_git" = "$tree_bit" ]
    done

    local status_git
    local status_bit
    status_git=$(git -C "$repo_git" status --porcelain)
    status_bit=$(git -C "$repo_bit" status --porcelain)
    [ -z "$status_git" ]
    [ -z "$status_bit" ]
}

run_case() {
    local seed="$1"
    local steps="$2"
    local max_branches="$3"
    local work="$TRASH_DIR/work_$seed"
    mkdir -p "$work"

    local ops="$work/ops.log"
    gen_ops "$seed" "$steps" "$max_branches" "$ops"

    apply_ops git "$work/repo_git" "$ops"
    apply_ops bit "$work/repo_bit" "$ops"

    compare_repos "$work/repo_git" "$work/repo_bit"
}

test_expect_success 'random add-pack ops seed=801' '
    run_case 801 55 4
'

test_expect_success 'random add-pack ops seed=802' '
    run_case 802 55 4
'

test_expect_success 'random add-pack ops seed=803' '
    run_case 803 55 4
'

test_expect_success 'random add-pack ops seed=804' '
    run_case 804 55 4
'

test_done
