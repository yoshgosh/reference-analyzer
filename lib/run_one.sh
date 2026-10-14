#!/usr/bin/env bash
# 1資源の処理の流れ（骨格）
#
# 手動（bin/ref）と自動（lib/process_inbox.sh）が共有する．
# 経路ごとに違うのは次の2つの関数だけで，呼び出し側が定義して差し替える．
#
#   prepare_target   対象を用意する（手動=補助資料を aux/ へコピー／自動=inbox から mv で取り込む）
#                    成功したら自動は step_completed fetch を記録する．
#                    失敗したら ERROR_MESSAGE を設定して 1 を返す．
#                    対象そのもののコピーは共有側（stage_target）が行う．
#   place_result     結果に応じてファイルを配置する（手動=原本を改名／自動=改名して移動）
#                    引数は解析と登録が成功なら 1．ステップを step_completed / step_failed で記録し，
#                    ファイルが動いたら CURRENT_PATH を更新する．返り値は見ない．
#
# 全体の成否は「全ステップが completed か」だけで決まる（lib/core.sh の steps_all_completed）．
#
# 呼び出し側が設定する変数:
#   RUN_MODE         auto | manual
#   TARGET_KIND      file | url
#   TARGET_PATH      対象ファイルの実パス（file のとき．自動は prepare_target が設定する）
#   TARGET_LABEL     ファイル名 または URL．作業ディレクトリ内のコピーもこの名前になる
#   AUX_DESC         プロンプトの「補助資料」に入れる記述（空でよい）
#   REDO_COMMAND     解析の前で失敗したときに next: に出すやり直しのコマンド
#   CURRENT_PATH     対象ファイルのいまの場所．run_one を呼ぶ前に設定し，
#                    ファイルが動くたびに更新する（通知はこれだけを出す）
#   STEP_LIST        通知に出すステップ（経路に存在するものだけ）
#   AUX_SUMMARY      通知の with: に出す補助資料（手動のみ．空でよい）

prepare_target() { return 0; }
place_result()   { return 0; }

# 対象のコピーを作業ディレクトリに置く．AI に見せるのはコピーだけで，原本には触れさせない
stage_target() {
  [ "$TARGET_KIND" = file ] || return 0
  if ! cp "$TARGET_PATH" "$WORK_DIR/$TARGET_LABEL"; then
    ERROR_MESSAGE="作業ディレクトリへコピーできなかった: $TARGET_PATH"
    return 1
  fi
  log_msg "作業ディレクトリへコピーした: $TARGET_LABEL"
}

run_one() {
  local done=0

  # 枠は「1資源を処理する許可」である．先に取るので，待っているプロセスは
  # 対象ファイルを掴まない．これが唯一の同時実行の制御点である．
  acquire_slot || true
  begin_run "$TARGET_KIND"

  # 開始の通知は枠を取得した直後に出す（待機中のものは出さない）．
  # 対象の用意より前に出すので，用意に失敗したことも通知できる．
  notify_start

  if ! prepare_target || ! stage_target; then
    if [ -z "${ERROR_MESSAGE:-}" ]; then ERROR_MESSAGE="対象を用意できなかった"; fi
    log_msg "失敗: $ERROR_MESSAGE"
    notify_result
    release_slot
    return 1
  fi

  # 改名・移動はページを作れたときだけ行う．失敗したら対象に触らない
  analyze && create_page && done=1
  place_result "$done"

  save_records
  save_state
  log_msg "ステップ: $(steps_log)"
  notify_result

  if steps_all_completed; then
    release_slot
    cleanup_work_dir
    return 0
  fi

  log_msg "失敗: ${ERROR_MESSAGE:-不明}"
  release_slot
  # 失敗時は調査用に作業ディレクトリを残す（保存期間の削除対象に含める）
  return 1
}
