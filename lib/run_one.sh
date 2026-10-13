#!/usr/bin/env bash
# 1資源の処理の流れ（骨格）
#
# 手動（bin/ref）と自動（lib/process_inbox.sh）が共有する．
# 経路ごとに違うのは次の2つの関数だけで，呼び出し側が定義して差し替える．
#
#   prepare_target   対象を作業ディレクトリへ用意する（手動=コピー／自動=mv で確保）
#                    失敗したら 1 を返す．その場合は記録も通知もせず静かに終わる．
#   place_result     結果に応じてファイルを配置する（手動=原本を改名／自動=改名して移動）
#                    引数は解析が成功なら 1．できたステップを step_ok で記録し，
#                    人に見せる1行を PLACEMENT に設定する．返り値は見ない．
#
# 全体の成否は「全ステップが ok か」だけで決まる（lib/core.sh の steps_all_ok）．
#
# 呼び出し側が設定する変数:
#   RUN_MODE         auto | manual
#   TARGET_KIND      file | url
#   TARGET_LABEL     通知やログに出す表示名
#   TARGET_DESC      プロンプトの「今回の対象」に入れる記述
#   AUX_DESC         プロンプトの「補助資料」に入れる記述（空でよい）
#   STEP_LIST        通知に出すステップ（経路に存在するものだけ）

prepare_target() { return 0; }
place_result()   { PLACEMENT=""; return 0; }

run_one() {
  local analyzed=0

  # 枠は「1資源を処理する許可」である．先に取るので，待っているプロセスは
  # 対象ファイルを掴まない．これが唯一の同時実行の制御点である．
  acquire_slot || true
  begin_run "$TARGET_KIND"

  if ! prepare_target; then
    log_msg "対象を用意できなかった．何もせず終了する"
    release_slot
    discard_run_dirs
    return 0
  fi

  # 開始の通知は枠を取得した後に出す（待機中のものは出さない）
  notify_start "$TARGET_LABEL"

  analyze "$TARGET_DESC" "${AUX_DESC:-}" && analyzed=1

  PLACEMENT=""
  place_result "$analyzed"

  save_records
  log_msg "ステップ: $(steps_log)"
  notify_result

  if steps_all_ok; then
    release_slot
    cleanup_work_dir
    return 0
  fi

  log_msg "未完了: ${ERROR_MESSAGE:-不明}"
  release_slot
  # 失敗時は調査用に作業ディレクトリを残す（保存期間の削除対象に含める）
  return 1
}
