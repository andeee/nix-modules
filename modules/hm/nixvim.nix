{ inputs, ... }:
{
  flake.modules.homeManager.nixvim = { pkgs, lib, ... }: {
    imports = [ inputs.nixvim.homeModules.nixvim ];

    programs.nixvim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      vimdiffAlias = true;
      defaultEditor = true;

      # vim.g.* settings
      globals = {
        mapleader = " ";
        maplocalleader = " ";
      };

      # vim.o.* settings
      opts = {
        exrc = true;
        number = true;
        relativenumber = true;
        hlsearch = true;
        ignorecase = true;
        smartcase = true;
        tabstop = 4;
        shiftwidth = 4;
        expandtab = true;
        scrolloff = 25;
        colorcolumn = "120";
        wrap = false;
        mouse = "a";
        showmode = false;
        termguicolors = true;
        clipboard = "unnamedplus";
        breakindent = true;
        smartindent = true;
        undofile = true;
        signcolumn = "yes";
        updatetime = 250;
        timeoutlen = 300;
        completeopt = "menuone,noselect";
        list = true;
        listchars.__raw = ''{ tab = "\u{bb} ", trail = "\u{b7}", nbsp = "\u{2423}" }'';
        inccommand = "split";
        background = "dark";
      };

      # Keymaps (simple ones only; complex Lua goes in extraConfigLua)
      keymaps = [
        # Clear search highlight
        { mode = "n"; key = "<Esc>"; action = "<cmd>nohlsearch<CR>"; options = { desc = "Clear search highlight"; }; }
        # Neutralize space
        { mode = [ "n" "v" ]; key = "<Space>"; action = "<Nop>"; options = { silent = true; }; }
        # Disable arrow keys
        { mode = [ "n" "v" ]; key = "<Left>"; action = "<Nop>"; options = { silent = true; }; }
        { mode = [ "n" "v" ]; key = "<Right>"; action = "<Nop>"; options = { silent = true; }; }
        { mode = [ "n" "v" ]; key = "<Up>"; action = "<Nop>"; options = { silent = true; }; }
        { mode = [ "n" "v" ]; key = "<Down>"; action = "<Nop>"; options = { silent = true; }; }
        # Centered scrolling
        { mode = "n"; key = "<C-d>"; action = "<C-d>zz"; options = { desc = "Scroll down and center"; }; }
        { mode = "n"; key = "<C-u>"; action = "<C-u>zz"; options = { desc = "Scroll up and center"; }; }
        # Yank improvements
        { mode = "n"; key = "Y"; action = "y$"; options = { desc = "Yank to end of line"; }; }
        # Line movement in visual mode
        { mode = "x"; key = "J"; action = ":m '>+1<CR>gv=gv"; options = { desc = "Move selection down"; }; }
        { mode = "x"; key = "K"; action = ":m '<-2<CR>gv=gv"; options = { desc = "Move selection up"; }; }
        # Window navigation
        { mode = "n"; key = "<C-h>"; action = "<C-w>h"; options = { desc = "Move to left window"; }; }
        { mode = "n"; key = "<C-j>"; action = "<C-w>j"; options = { desc = "Move to window below"; }; }
        { mode = "n"; key = "<C-k>"; action = "<C-w>k"; options = { desc = "Move to window above"; }; }
        { mode = "n"; key = "<C-l>"; action = "<C-w>l"; options = { desc = "Move to right window"; }; }
        # Window management
        { mode = "n"; key = "<leader>wh"; action = "<C-w>s"; options = { desc = "Split horizontal"; }; }
        { mode = "n"; key = "<leader>wv"; action = "<C-w>v"; options = { desc = "Split vertical"; }; }
        { mode = "n"; key = "<leader>wd"; action = "<C-w>q"; options = { desc = "Close window"; }; }
        { mode = "n"; key = "<leader>ww"; action = "<C-w>w"; options = { desc = "Next window"; }; }
        # Buffer management
        { mode = "n"; key = "<leader>bn"; action = ":bnext<CR>"; options = { desc = "Next buffer"; }; }
        { mode = "n"; key = "<leader>bp"; action = ":bprevious<CR>"; options = { desc = "Previous buffer"; }; }
        { mode = "n"; key = "<leader>bd"; action = ":bdelete<CR>"; options = { desc = "Close buffer"; }; }
        { mode = "n"; key = "<leader>bD"; action = ":bdelete!<CR>"; options = { desc = "Force close buffer"; }; }
        # Telescope search keymaps
        { mode = "n"; key = "<leader><space>"; action.__raw = "require('telescope.builtin').buffers"; options = { desc = "[ ] Find existing buffers"; }; }
        { mode = "n"; key = "<leader>?"; action.__raw = "require('telescope.builtin').oldfiles"; options = { desc = "[?] Find recently opened files"; }; }
        { mode = "n"; key = "<leader>sh"; action.__raw = "require('telescope.builtin').help_tags"; options = { desc = "[S]earch [H]elp"; }; }
        { mode = "n"; key = "<leader>sk"; action.__raw = "require('telescope.builtin').keymaps"; options = { desc = "[S]earch [K]eymaps"; }; }
        { mode = "n"; key = "<leader>ss"; action.__raw = "require('telescope.builtin').builtin"; options = { desc = "[S]earch [S]elect Telescope"; }; }
        { mode = "n"; key = "<leader>sw"; action.__raw = "require('telescope.builtin').grep_string"; options = { desc = "[S]earch current [W]ord"; }; }
        { mode = "n"; key = "<leader>sg"; action.__raw = "require('telescope.builtin').live_grep"; options = { desc = "[S]earch by [G]rep"; }; }
        { mode = "n"; key = "<leader>sd"; action.__raw = "require('telescope.builtin').diagnostics"; options = { desc = "[S]earch [D]iagnostics"; }; }
        { mode = "n"; key = "<leader>sr"; action.__raw = "require('telescope.builtin').resume"; options = { desc = "[S]earch [R]esume"; }; }
        # Document symbols
        { mode = "n"; key = "<leader>ls"; action.__raw = "require('telescope.builtin').lsp_document_symbols"; options = { desc = "[L]ist [S]ymbols"; }; }
        # Oil
        { mode = "n"; key = "-"; action = "<CMD>Oil<CR>"; options = { desc = "Open parent directory"; }; }
        # Git
        { mode = "n"; key = "<leader>gg"; action = ":Neogit<CR>"; options = { desc = "Open Neogit"; }; }
        { mode = "n"; key = "<leader>gd"; action = ":DiffviewOpen<CR>"; options = { desc = "Open diff view"; }; }
        { mode = "n"; key = "<leader>gh"; action = ":DiffviewFileHistory<CR>"; options = { desc = "Open file history"; }; }
        { mode = "n"; key = "<leader>gc"; action = ":DiffviewOpen<CR>"; options = { desc = "Conflict resolution"; }; }
        # Visual paste without yanking
        { mode = "x"; key = "p"; action = "\"_dP"; options = { desc = "Paste without yanking replaced text"; }; }
        # Quick buffer switch
        { mode = [ "n" "i" ]; key = "<leader><leader>"; action = ":b#<CR>"; options = { desc = "Switch to last buffer"; }; }

        # old init_selection: select the node under the cursor
        {
          mode = "n";
          key = "<C-Space>";
          action.__raw = ''
            function()
              vim.cmd("normal v")
              vim.treesitter.select("parent")
            end
          '';
          options = { desc = "TS select: node under cursor"; };
        }
        # old node_incremental / node_decremental
        {
          mode = "x";
          key = "<C-Space>";
          action.__raw = ''function() vim.treesitter.select("parent") end'';
          options = { desc = "TS select: expand"; };
        }
        {
          mode = "x";
          key = "<M-Space>";
          action.__raw = ''function() vim.treesitter.select("child") end'';
          options = { desc = "TS select: shrink"; };
        }
      ];

      # Autocommand groups
      autoGroups = {
        highlight_yank = { clear = true; };
        kickstart_lsp_attach = { clear = true; };
        lint = { clear = true; };
      };

      # Autocommands
      autoCmd = [
        # Highlight on yank
        {
          event = "TextYankPost";
          group = "highlight_yank";
          callback.__raw = ''
            function()
              vim.highlight.on_yank()
            end
          '';
        }
        # LSP attach
        {
          event = "LspAttach";
          group = "kickstart_lsp_attach";
          callback.__raw = ''
            function(event)
              local nmap = function(keys, func, desc)
                if desc then desc = "LSP: " .. desc end
                vim.keymap.set("n", keys, func, { buffer = event.buf, desc = desc })
              end
              nmap("<a-CR>", vim.lsp.buf.code_action, "Code Action")
              nmap("gd", require("telescope.builtin").lsp_definitions, "[G]oto [D]efinition")
              nmap("gr", require("telescope.builtin").lsp_references, "[G]oto [R]eferences")
              nmap("gI", require("telescope.builtin").lsp_implementations, "[G]oto [I]mplementation")
              nmap("<leader>D", require("telescope.builtin").lsp_type_definitions, "Type [D]efinition")
              nmap("K", vim.lsp.buf.hover, "Hover Documentation")
              nmap("<C-k>", vim.lsp.buf.signature_help, "Signature Documentation")
              nmap("gD", vim.lsp.buf.declaration, "[G]oto [D]eclaration")
              local client = vim.lsp.get_client_by_id(event.data.client_id)
              if client and client.server_capabilities.documentHighlightProvider then
                vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
                  buffer = event.buf,
                  callback = vim.lsp.buf.document_highlight,
                  group = vim.api.nvim_create_augroup("document_highlight", { clear = true }),
                })
                vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
                  buffer = event.buf,
                  callback = vim.lsp.buf.clear_references,
                  group = vim.api.nvim_create_augroup("document_highlight", { clear = true }),
                })
              end
            end
          '';
        }
      ];

      colorscheme = "gruvbox-baby";
      colorschemes.gruvbox-baby = {
        enable = true;
        settings = {
          transparent_mode = 1;
          telescope_theme = 1;
        };
      };

      # Use our nixpkgs for nixvim (suppress follows warning)
      nixpkgs.source = inputs.nixpkgs;

      # Extra packages
      extraPackages = with pkgs; [
        nixd
        gopls
        bash-language-server
        vscode-langservers-extracted
        yaml-language-server
        nixpkgs-fmt
        gofumpt
        statix
        deadnix
      ];

      # Plugins
      plugins = {
        # Telescope
        telescope = {
          enable = true;
          extensions = {
            fzy-native.enable = true;
            ui-select.enable = true;
          };
          settings.defaults = {
            path_display = [ "filename_first" { truncate = 3; } ];
            layout_strategy = "flex";
            layout_config.flex.flip_columns = 200;
            mappings.i."<C-d>".__raw = "require('telescope.actions').delete_buffer + require('telescope.actions').move_to_top";
          };
        };

        treesitter = {
          enable = true;
          grammarPackages = pkgs.vimPlugins.nvim-treesitter.allGrammars;
          highlight.enable = true;
          indent.enable = true;
        };

        # Oil
        oil.enable = true;

        # Which-key
        which-key = {
          enable = true;
          settings.notify = false;
        };

        # Mini.nvim (ai + surround only)
        mini = {
          enable = true;
          mockDevIcons = true;
          modules = {
            icons = { };
            ai = { n_lines = 500; };
            surround = { };
            statusline = { };
            tabline = { };
            pairs = { };
          };
        };

        # nvim-cmp
        cmp = {
          enable = true;
          settings = {
            snippet.expand.__raw = ''
              function(args)
                require("luasnip").lsp_expand(args.body)
              end
            '';
            completion.completeopt = "menu,menuone,noinsert";
            mapping.__raw = ''
              cmp.mapping.preset.insert({
                ["<C-n>"] = cmp.mapping.select_next_item(),
                ["<C-p>"] = cmp.mapping.select_prev_item(),
                ["<C-d>"] = cmp.mapping.scroll_docs(-4),
                ["<C-f>"] = cmp.mapping.scroll_docs(4),
                ["<C-Space>"] = cmp.mapping.complete {},
                ["<C-y>"] = cmp.mapping.confirm { select = true },
                ["<C-l>"] = cmp.mapping(function(fallback)
                  if luasnip.expand_or_locally_jumpable() then
                    luasnip.expand_or_jump()
                  else
                    fallback()
                  end
                end, { "i", "s" }),
                ["<C-h>"] = cmp.mapping(function(fallback)
                  if luasnip.locally_jumpable(-1) then
                    luasnip.jump(-1)
                  else
                    fallback()
                  end
                end, { "i", "s" }),
              })
            '';
            sources = [
              { name = "nvim_lsp"; }
              { name = "luasnip"; keyword_length = 2; }
              { name = "buffer"; keyword_length = 3; }
              { name = "path"; }
            ];
          };
        };

        # LuaSnip
        luasnip = {
          enable = true;
          fromVscode = [{ }];
        };

        # comment-nvim
        comment.enable = true;

        # fidget-nvim
        fidget = {
          enable = true;
          settings.notification.window.winblend = 0;
        };

        # gitsigns
        gitsigns = {
          enable = true;
          settings = {
            signcolumn = true;
          };
        };

        # Trouble
        trouble = {
          enable = true;
          settings.auto_preview = true;
        };

        # todo-comments
        todo-comments = {
          enable = true;
        };

        # LSP
        lsp = {
          enable = true;
          servers = {
            nixd = {
              enable = true;
              settings = {
                formatting = {
                  command = [ "${lib.getExe pkgs.nixpkgs-fmt}" ];
                };
              };
            };
            gopls.enable = true;
            bashls.enable = true;
            jsonls.enable = true;
            yamlls.enable = true;
          };
        };

        # Conform (formatting, Nix + Go only)
        conform-nvim = {
          enable = true;
          settings = {
            format_on_save.__raw = ''
              function(bufnr)
                if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
                  return
                end
                return { timeout_ms = 500, lsp_format = "fallback" }
              end
            '';
            formatters_by_ft = {
              nix = [ "nixpkgs_fmt" ];
              go = [ "gofumpt" ];
            };
          };
        };

        # lint (Nix only)
        lint = {
          enable = true;
          lintersByFt.nix = [ "statix" "deadnix" ];
        };

        # Neogit
        neogit.enable = true;

        # Diffview
        diffview.enable = true;
      };

      # Extra plugins without native NixVim support
      extraPlugins = with pkgs.vimPlugins; [
        cmp-path
        cmp-buffer
        cmp-cmdline
        cmp-nvim-lsp
        cmp_luasnip
        friendly-snippets
        plenary-nvim
      ];

      # Extra Lua config
      extraConfigLua = ''
        -- Which-key group labels
        require("which-key").add({
          { "<leader>b", group = "Buffer" },
          { "<leader>f", group = "Find" },
          { "<leader>g", group = "Git" },
          { "<leader>l", group = "List" },
          { "<leader>s", group = "Search" },
          { "<leader>w", group = "Window" },
          { "<leader>x", group = "Trouble" },
        })

        -- Cmdline completion for nvim-cmp
        local cmp = require("cmp")
        cmp.setup.cmdline("/", {
          mapping = cmp.mapping.preset.cmdline(),
          sources = { { name = "buffer" } }
        })
        cmp.setup.cmdline(":", {
          mapping = cmp.mapping.preset.cmdline(),
          sources = cmp.config.sources(
            { { name = "path" } },
            { { name = "cmdline", option = { ignore_cmds = { "Man", "!" } } } }
          )
        })

        -- Autopairs + cmp integration (protected in case module is not available)
        local ok, cmp_autopairs = pcall(require, "nvim-autopairs.completion.cmp")
        if ok then
          cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
        end

        -- Gruvbox-baby handles its own setup via colorschemes.gruvbox-baby

        -- Telescope keymaps with options (not expressible via NixVim keymaps)
        vim.keymap.set("n", "<leader>sf", function()
          require("telescope.builtin").find_files { hidden = true, follow = true }
        end, { desc = "[S]earch [F]iles" })
        vim.keymap.set("n", "<leader>s/", function()
          require("telescope.builtin").live_grep {
            grep_open_files = true,
            prompt_title = "Live Grep in Open Files",
          }
        end, { desc = "[S]earch [/] in Open Files" })

        -- Conform commands
        vim.api.nvim_create_user_command("FormatDisable", function(args)
          if args.bang then
            vim.b.disable_autoformat = true
          else
            vim.g.disable_autoformat = true
          end
        end, { desc = "Disable autoformat-on-save", bang = true })
        vim.api.nvim_create_user_command("FormatEnable", function()
          vim.b.disable_autoformat = false
          vim.g.disable_autoformat = false
        end, { desc = "Re-enable autoformat-on-save" })

        -- Nvim-lint autocmd
        vim.api.nvim_create_autocmd({ "BufWritePost" }, {
          group = vim.api.nvim_create_augroup("lint", { clear = true }),
          callback = function() require("lint").try_lint() end,
        })

        -- Gitsigns hunk keymaps
        vim.keymap.set("n", "<leader>gp", require("gitsigns").preview_hunk, { desc = "Preview hunk" })
        vim.keymap.set("n", "<leader>gs", require("gitsigns").stage_hunk, { desc = "Stage hunk" })
        vim.keymap.set("n", "<leader>gr", require("gitsigns").reset_hunk, { desc = "Reset hunk" })
        vim.keymap.set("n", "<leader>gb", require("gitsigns").blame_line, { desc = "Blame line" })

        -- Trouble keymaps
        vim.keymap.set("n", "<leader>xx", function() require("trouble").toggle() end, { desc = "Toggle Trouble" })
        vim.keymap.set("n", "<leader>xw", function() require("trouble").toggle("workspace_diagnostics") end, { desc = "Workspace diagnostics" })
        vim.keymap.set("n", "<leader>xd", function() require("trouble").toggle("document_diagnostics") end, { desc = "Document diagnostics" })
        vim.keymap.set("n", "<leader>xq", function() require("trouble").toggle("quickfix") end, { desc = "Quickfix list" })
        vim.keymap.set("n", "<leader>xl", function() require("trouble").toggle("loclist") end, { desc = "Location list" })

        -- Todo-comments telescope keymap
        vim.keymap.set("n", "<leader>ft", function()
          require("telescope.builtin").todos()
        end, { desc = "Find [T]odos" })

        -- Diagnostic keymaps (set here to avoid __raw quoting issues in Nix)
        vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Go to previous diagnostic message" })
        vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Go to next diagnostic message" })
        vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Show diagnostic error message" })

        -- Word wrap navigation (expr maps with Nix raw strings are fragile)
        vim.keymap.set("n", "k", [[v:count == 0 ? 'gk' : 'k']], { expr = true, silent = true })
        vim.keymap.set("n", "j", [[v:count == 0 ? 'gj' : 'j']], { expr = true, silent = true })
      '';
    };
  };
}
