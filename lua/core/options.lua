local M = {}

function M.get_common_options()
  return {
    shortcuts = {
      close_tab = "q",
      activate = { "<CR>", "<2-LeftMouse>" },
      scroll_backward = "<C-b>",
      scroll_forward = "<C-f>",
      prev_file = "<S-TAB>",
      next_file = "<TAB>",
    }
  }
end

function M.get_log_options()
  return vim.tbl_deep_extend("force", M.get_common_options(), {
    shortcuts = {
      filters = "g!",
      yank_commit = "y",
      open_log = "L",
    },
    relative_date_cutoff_seconds = 3 * 24 * 60 * 60,
    panel_height = 15,
    default_max_items = 256,
  })
end

function M.get_stashes_options()
  return vim.tbl_deep_extend("force", M.get_log_options(), {
    shortcuts = {
      unstash = "<C-enter>",
      drop_stash = "<C-del>",
    },
  })
end

function M.get_diff_options()
  return vim.tbl_deep_extend("force", M.get_common_options(), {
    shortcuts = {
      jump_to_first = "F",
      mark_file_for_diff = "+",
      yank_commit = "y",
    },
    panel_width = 40,
  })
end

function M.get_revspec_options()
  return vim.tbl_deep_extend("force", M.get_diff_options(), {
    shortcuts = {
      open_log = "L",
    },
    diff_log_panel_height_ratio = 0.6,
    relative_date_cutoff_seconds = 3 * 24 * 60 * 60,
  })
end

function M.get_status_options()
  return vim.tbl_deep_extend("force", M.get_diff_options(), {
    shortcuts = {
      stage_unstage = "s",
      drop_changes = "X",
      open_conflict_commits = "L",
      conflict_modal_switch_commit = "<TAB>",
      conflict_previous = "[x",
      conflict_next = "]x",
      conflict_choose_ours = "<leader>co",
      conflict_choose_theirs = "<leader>ct",
      conflict_choose_all = "<leader>ca",
      all_conflicts_choose_ours = "<leader>cO",
      all_conflicts_choose_theirs = "<leader>cT",
      all_conflicts_choose_all = "<leader>cA",
    },
    conflicts_display_mode = "ours_local_theirs", -- also supported: ours_local_theirs_base
  })
end

function M.apply_option_defaults(opts, defaults)
  return vim.tbl_deep_extend("keep", opts or {}, defaults)
end

return M
