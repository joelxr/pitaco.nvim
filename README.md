# Pitaco Neovim Plugin 🚀

Welcome to the **Pitaco** Neovim plugin! This is an experimental plugin designed to provide you with an AI reviewer right inside your Neovim editor. With Pitaco, you can anticipate issues and improve your code before pushing to remote repositories.

## Features ✨

- **Repository-aware reviews**: Review the current branch diff or the entire current file with `:Pitaco`, `:Pitaco review`, `:Pitaco diff`, `:Pitaco file`, or `:PitacoReview`.
- **Local codebase indexing**: Build and refresh semantic repository context with `:Pitaco index` or `:PitacoIndex`.
- **Persistent review history**: Completed reviews are stored on disk with repo/model/hash metadata and can be reopened later with `:Pitaco reviews`.
- **Diagnostics workflow**: Publish findings through Neovim diagnostics, restore them when files are reopened, clear the active review with `:Pitaco clear`, hide the current line with `:Pitaco clearLine`, or insert a diagnostics summary comment with `:Pitaco comment`.
- **AI-assisted commits**: Generate commit messages from current git changes with `:Pitaco commit`.
- **Runtime model switching**: Pick and persist provider/model selections with `:Pitaco models [scope]`.
- **Session language override**: Inspect or override the active response language with `:Pitaco language [value]`.
- **Built-in health checks**: Validate provider setup and dependencies with `:Pitaco health`.

> **Note**: Pitaco uses the native Neovim diagnostics API, making it easy to integrate with other plugins such as `folke/trouble.nvim` for enhanced diagnostics visualization.

## Installation 📦

To install Pitaco, use your preferred Neovim plugin manager. For example, with `lazy.nvim`:

```lua
require('lazy').setup({
    'joelxr/pitaco.nvim',
    dependencies = {
        'nvim-lua/plenary.nvim',
        'j-hui/fidget.nvim',
        -- optional: improved commit UI
        'MunifTanjim/nui.nvim',
    },
        config = function()
            require('pitaco').setup({
                -- minimal configuration, see below for more options
                provider = "openai",
                model_id = "gpt-4.1-mini",
            })
        end,
    })
```

Then, restart Neovim and run `:Lazy install`.

Pitaco has the following dependencies:
- `nvim-lua/plenary.nvim`
- `curl`

Optional dependency:
- `MunifTanjim/nui.nvim` (required for `:Pitaco models [scope]`, and used for an enhanced `:Pitaco commit` UI with fallback if missing)

## Usage 🛠️

Once installed, you can use the following commands to interact with Pitaco:

- `:Pitaco` - Review the full branch diff against `main` or `master` and publish findings via the Neovim diagnostics API.
- `:Pitaco review [diff|file]` - Review the full branch diff against `main`/`master`, or the entire current file. Defaults to `diff`.
- `:Pitaco diff` / `:Pitaco file` - Shorthand aliases for `:Pitaco review diff` and `:Pitaco review file`.
- `:PitacoReview [diff|file]` - Alias for repository-aware review. Defaults to `diff`.
- `:Pitaco index` / `:PitacoIndex` - Build or update the local repository index used for contextual review.
- `:Pitaco clear` - Clear the current review.
- `:Pitaco clearLine` - Clear the current review for the current line.
- `:Pitaco comment` - Add a comment under the current line with the Pitaco diagnostics summary.
- `:Pitaco reviews` - Open the stored review history for the current repository and reactivate a review.
- `:Pitaco commit` - Generate a commit message from git changes and confirm the commit.
- `:Pitaco health` - Run Pitaco checks with `:checkhealth pitaco`.
- `:Pitaco models [default|scope]` - Open a model picker for the base config or a feature scope such as `review` or `commit`.
- `:Pitaco summary` - Show the resolved runtime Pitaco summary, including active provider/model selections per scope.
- `:Pitaco debug [on|off|toggle]` - Show or change the plugin debug mode for the current Neovim session.
- `:Pitaco language [value]` - Show current language, or override it for this Neovim session.
  - Use `:Pitaco language default` (or `reset`) to clear session override and return to setup value.

## Configuration ⚙️

To use Pitaco, you need to set up one of the following environment variables, depending on your LLM API provider:

- `OPENAI_API_KEY` - For OpenAI API.
- `ANTHROPIC_API_KEY` - For Anthropic API.
- `OPENROUTER_API_KEY` - For OpenRouter API.

Those keys are required to authenticate requests. You can set it in your shell configuration file (e.g., `.bashrc`, `.zshrc`):

Exmaple:

```bash
export OPENAI_API_KEY="your-openai-api-key"
export ANTHROPIC_API_KEY="your-anthropic-api-key"
export OPENROUTER_API_KEY="your-openrouter-api-key"
```

> **Disclaimer**: Currently, Pitaco only supports those providers. However, support for additional models is planned in the roadmap.

For `ollama`, no API key is required. You may set:
- `model_id` (default: `llama3.1` when `provider = "ollama"`)
- `ollama_url` (default: `http://localhost:11434`)

You can configure Pitaco by adding the following to your Neovim configuration file:

```lua
require('pitaco').setup({
    provider = "anthropic", -- Base/default provider used when a feature does not override it
    model_id = "claude-haiku-4-5", -- Base/default model for the selected provider
    ollama_url = "http://localhost:11434",
    language = "english",
    review_additional_instruction = nil,
    commit_additional_instruction = nil,
    debug = false, -- Enable request/response debug logs via vim.notify
    commit_keymap = "<leader>at", -- Optional mapping for :Pitaco commit
    persist_model_selection = true, -- Save :Pitaco models [scope] selections in the state file
    features = {
        review = {
            provider = "openrouter",
            model_id = "openrouter/deepseek/deepseek-chat-v3-0324:free",
        },
        commit = {
            provider = "openai",
            model_id = "gpt-5-mini",
        },
    },
    context_enabled = true,
    context_cli_cmd = "pitaco-indexer", -- Or { "node", "/absolute/path/to/indexer/src/cli.js" }
    context_max_chunks = 6,
    context_timeout_ms = 1500,
    context_include_git_diff = true,
})
```

`language` defaults to `english` and is used for both review responses and generated commit subjects.
You can temporarily override it during the current Neovim session with:

```vim
:Pitaco language portuguese
```

`review_additional_instruction` is appended to review requests.
`commit_additional_instruction` is appended to the commit-message prompt.
`additional_instruction` is still accepted as a backward-compatible alias for `review_additional_instruction`.

Provider/model selection resolves like this:
- Base defaults come from `provider` and `model_id`.
- Feature-specific overrides can be set under `features.<name>`.
- Each feature may set `provider` and `model_id`.
- If a feature changes `provider` without setting `model_id`, Pitaco falls back to that provider's built-in default model.
- `review` and `commit` already use scoped resolution, and future features can reuse the same mechanism.

Example with base defaults plus per-feature overrides:

```lua
require("pitaco").setup({
    provider = "anthropic",
    model_id = "claude-haiku-4-5",
    features = {
        review = {
            provider = "anthropic",
            model_id = "claude-haiku-4-5",
        },
        commit = {
            provider = "openai",
            model_id = "gpt-5-mini",
        },
    },
})
```

Flat aliases such as `review_provider`, `review_model_id`, `commit_provider`, and `commit_model_id` are also accepted, but `features = { ... }` is the preferred format going forward.

`persist_model_selection` stores base and scoped provider/model selections in:
- `stdpath("state") .. "/pitaco-model-state.json"`

`:Pitaco models` changes the base/default provider and model.
`:Pitaco models commit` or `:Pitaco models review` changes that feature's scoped provider/model override and shows the current selection in the picker header.
`:Pitaco summary` reports the resolved runtime provider/model for the default scope and every configured feature scope, so inherited and fallback models are visible.
`:Pitaco debug on`, `:Pitaco debug off`, and `:Pitaco debug toggle` change the live debug flag without re-running `setup()`.

### Repository-aware review

Pitaco can enrich review prompts with relevant repository context retrieved from a local index.
Reviews are sent as a single repository-aware request, not split into smaller chunks.
Both review modes publish findings through Neovim's diagnostics API.
Completed reviews are also persisted under `stdpath("state")`, including provider/model metadata, commit hashes, and findings.
When a file is reopened, Pitaco restores diagnostics for the active stored review and attempts to relocate findings using nearby source context.
If relocation fails, the finding is rendered on line `1` with a stale marker.
Diff mode compares the current branch state against the local `main` branch when available, otherwise `master`.

Review flow:

```text
repo -> pitaco-indexer index -> .repo-pitaco/index
buffer review (branch diff|file) -> pitaco-indexer search <file> -> relevant chunks -> LLM review prompt
```

The indexer:
- scans repository files while ignoring `.git`, `.repo-pitaco`, `node_modules`, `dist`, `build`, `target`, and `vendor`
- parses supported files with tree-sitter
- extracts semantic chunks for functions, classes, methods, and file-level fallbacks
- stores embeddings and metadata under `.repo-pitaco/index`
- reindexes only files whose hash or modification time changed

Supported languages:
- TypeScript / TSX
- JavaScript / JSX
- Lua
- Go
- Python

Install the local CLI from this repository:

```bash
cd indexer
npm install
npm link
```

The `indexer/` workspace includes an `.npmrc` with `legacy-peer-deps=true` because the published tree-sitter grammar packages currently declare conflicting optional peer ranges for `tree-sitter`.

If you use `lazy.nvim` or LazyVim, you can install the indexer dependencies as part of the plugin spec and point Pitaco at the local script instead of using `npm link`:

```lua
{
    "joelxr/pitaco.nvim",
    dependencies = {
        "nvim-lua/plenary.nvim",
    },
    build = function(plugin)
        vim.fn.system({
            vim.fn.exepath("npm"),
            "install",
            "--prefix",
            plugin.dir .. "/indexer",
        })
    end,
    config = function(plugin)
        require("pitaco").setup({
            context_cli_cmd = {
                vim.fn.exepath("node"),
                plugin.dir .. "/indexer/src/cli.js",
            },
        })
    end,
}
```

After changing the plugin spec, run `:Lazy sync` or `:Lazy build pitaco.nvim` so the `indexer/` dependencies are installed.

If you do not want to link it globally, point Pitaco directly at the local script:

```lua
require("pitaco").setup({
    context_cli_cmd = { vim.fn.exepath("node"), "/absolute/path/to/pitaco.nvim/indexer/src/cli.js" },
})
```

Optional indexer configuration lives at `.repo-pitaco/config.json`:

```json
{
  "embedding": {
    "provider": "ollama",
    "model": "nomic-embed-text",
    "baseUrl": "http://localhost:11434"
  },
  "search": {
    "limit": 6
  }
}
```

Recommended embedding providers:
- `ollama` with `nomic-embed-text`
- `openai` with `text-embedding-3-small`
- `openrouter` with `text-embedding-3-small`

When no remote embedding provider is configured, the indexer falls back to a local hashed embedding so the workflow still works offline.

When `debug = true`, Pitaco emits request lifecycle logs for provider calls, including payload previews, HTTP status, decode failures, and response previews.

The model picker discovers models from provider APIs (with default fallback when needed), including:
- provider readiness (key configured / ollama reachable)
- plan and per-1M pricing when available
- balance when available (for OpenRouter credits)
- NUI modal picker with model status and metadata per entry
- picker keys:
  - `/` search/filter models
  - `c` clear search
  - `j`/`k` or arrows to navigate, `Enter` to select

### Health checks

`Pitaco health` / `checkhealth pitaco` verifies:
- required tools/deps (`plenary.nvim`, `curl`)
- optional commit UI dependency (`nui.nvim`)
- selected provider validity (`openai`, `anthropic`, `openrouter`, `ollama`)
- model setup for each provider (warns when relying on defaults)
- API keys for cloud providers:
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
  - `OPENROUTER_API_KEY`
- Ollama setup:
  - URL format (`ollama_url`)
  - endpoint reachability (`/api/tags`)

### Diagnostics UI

If you want you can setup better UI for diagnostics on Neovim, you can:
 - use [folke/trouble.nvim](https://github.com/folke/trouble.nvim) to show the diagnostics in a different panel and leverage all the features of it
 - have a mapping to `vim.diagnostic.open_float` to show the diagnostics in a floating window of the current line
 - setup the editor to display custom icons and colors for diagnostics
 - setup Pitaco to run when the buffer is loaded or saved (I would only recommend this if you are using a free model like the ones provided by OpenRouter)

See example below of those options:

```lua
-- Example of a mapping to show the diagnostics in the current line
vim.keymap.set("n", "<leader>do", vim.diagnostic.open_float)
````

```lua
-- Example mapping for the Pitaco commit command
vim.keymap.set("n", "<leader>at", "<cmd>Pitaco commit<CR>", { desc = "Pitaco commit" })
```

```lua
-- Example of better diagnostics on buffer with icons and colors
vim.diagnostic.config({
    signs = {
		text = {
			[vim.diagnostic.severity.ERROR] = " ",
			[vim.diagnostic.severity.WARN] = " ",
			[vim.diagnostic.severity.INFO] = " ",
			[vim.diagnostic.severity.HINT] = "󰠠 ",
		},
		linehl = {
			[vim.diagnostic.severity.ERROR] = "Error",
			[vim.diagnostic.severity.WARN] = "Warn",
			[vim.diagnostic.severity.INFO] = "Info",
			[vim.diagnostic.severity.HINT] = "Hint",
		},
	},
    severity_sort = true,
    float = true,
})
```

### `lualine` integration

You can use [nvim-lualine/lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) to display Pitaco's progress in your statusline.

```lua
-- Example of a lualine component to display Pitaco's progress
lualine_x = {
    {
        function()
            -- It can be any kind of spinner
            local spinner = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
            local pitaco_state = require("pitaco.progress").get_state()

            if not pitaco_state.running then
                return ""
            end

            return spinner[os.date("%S") % #spinner + 1]
        end,
    },
```

### `j-hui/fidget.nvim` integration

You can use [j-hui/fidget.nvim](https://github.com/j-hui/fidget.nvim) to display Pitaco's progress in your statusline.
You just need to use `PitacoProgressUpdate` and `PitacoProgressStop` autocmds to update the progress and stop the progress respectively.

```lua
-- Example of a fidget component to display Pitaco's progress
local handle

vim.api.nvim_create_autocmd("User", {
    pattern = "PitacoProgressUpdate",
    callback = function(args)
        local progress = require("fidget.progress")
        local data = args.data

        if not handle then
            handle = progress.handle.create({
                title = "Pitaco",
                message = data.message,
                percentage = data.percentage,
                lsp_client = { name = "pitaco" },
            })
        else
            handle:report({
                message = data.message,
                percentage = data.percentage,
            })
        end

        if not data.running then
            if handle then
                handle:finish()
                handle = nil
            end
        end
    end,
})

vim.api.nvim_create_autocmd("User", {
    pattern = "PitacoProgressStop",
    callback = function()
        if handle then
            handle:finish()
            handle = nil
        end
    end,
})
end,
```

### Run on file open

```lua
-- Example of how to setup Pitaco to run on file open
vim.api.nvim_create_autocmd("BufRead", {
	callback = function()
		local fileType = vim.bo.filetype
        local desiredFileTypes = { "javascript", "typescript", "vue", "html", "markdown", "python", "rust", "go", "java", "c", "cpp", "lua" }
        
		if vim.tbl_contains(desiredFileTypes, fileType) then
			vim.cmd("Pitaco")
		end
	end,
})
```

## Contributing 🤝

Contributions are welcome! Please fork the repository and submit a pull request.

## Roadmap 🛣️

- [x] Support for Anthropic models
- [x] Integration with OpenRouter
- [ ] Support for Gemini models
- [ ] Integration with Deepseek
- [x] Support for Ollama models

## License 📄

This project is licensed under the MIT License.

## Acknowledgments 🙏

Thanks to the Neovim community and all contributors for their support.

A big thanks to [james1236/backseat.nvim](https://github.com/james1236/backseat.nvim) for inspiration.
