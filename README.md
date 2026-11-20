# Nanodiff

## Introduction

![Screenshot](https://github.com/user-attachments/assets/19e4db3c-74ab-45d6-ac82-2e1493082ce3)

This is a neovim plugin to explore tree differences in source control.
It is very inspired by [diffview.nvim](https://github.com/sindrets/diffview.nvim).

It leverages neovim's diff mode displaying two-way diffs. Like diffview.nvim, it is a single-tabpage plugin.

Nanodiff requires neovim 0.13 (in particular it uses vim.async).

It offers four main functions:

- `status`: visualize untracked, unstaged, stages files, can stage/unstage files
- `revspec`: can display tree differences based on a git "revspec", for instance `...feature_branch`, or `commit^..commit` to view a single commit. Will display diff+log
- `log`: view a list of recents commits in the current branch
- `stashes`: view and restore stashes

In theory, nanodiff could get support for other version control systems than git. The way it could work is that you give as parameter
to individual functions a `vcs_adapters` list, that can include the bundled git adapter, or any other adapter. There could then be
a `nanodiff-hg` plugin, and so on. This base plugin will only ever contain the git plugin.
If someone is interested in attempting this, let me know, I'll be happy to help and link to the project from here if it works out.

A core value of this plugin is attempting for the plugin to remain as lean as possible (it is already too large for my liking, although still
smaller than most comparable plugins).

## Installing + using

```lua
vim.pack.add{ 'https://github.com/emmanueltouzery/nanodiff.nvim' }
```

No need to call a setup function. You should probably bind keyboard shortcuts to the main functions, for instance:

```lua
vim.keymap.set("n", "<leader>gg", function()
  require('nanodiff').status()
end, {desc="git status"})

vim.keymap.set("n", "<leader>gl", function()
  require('nanodiff').log()
end, {desc="git log"})

vim.keymap.set("n", "<leader>gl", function()
  require('nanodiff').stashes()
end, {desc="git stashes"})
```

For revspec, there is a mandatory first parameter, [the revspec](https://git-scm.com/docs/gitrevisions). For me, I don't map it to
a specific keyboard shortcut, but i invoke it from multiple places: in general telescope pickers, for branches, for commits and so on.
Typically it would be used to compare a branch with another one, for instance to review a pull request. In that case, the revspec would
probably be `...branch_to_review`.

## API

Besides the main functions, nanodiff also exports a `nanodiff.lib` module. It contains the `filetree`, `tabdata` and `io_helpers` modules.
To get information about the displayed data, the `tabdata` module's function `get_data()` should be of great interest. You can view its
contents using:

```
:= require('nanodiff').lib.tabdata.get_data()
```
