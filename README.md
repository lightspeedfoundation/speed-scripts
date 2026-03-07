# Speed-CLI · Advanced Scripts

Open-source access to **Speed-CLI** and advanced automation scripts. Scripts wrap and extend the [Speed-CLI](https://www.npmjs.com/package/@lightspeed-cli/speed-cli) for multichain swaps, bridges, balances, and agent identities.

**Speed-CLI** is an agentic command-line interface: swap any token (0x), bridge (Squid), check balances/prices/volume, run DCA, estimate gas, track XP — and manage permanent `.speed` agent identities on Base, tradeable via SANS on OpenSea. All config and secrets live in `~/.speed`. Use `--json` and `-y` on commands for script and agent use.

---

## Scripts layout

Scripts live under **one folder per advanced function**:

```
scripts/
├── README.md
├── limit-order-any/
│   ├── limit-order-any.ps1    # runnable script
│   └── limit-order-skill.md   # syntax, params, flow for agents
└── <other-function>/
    ├── <script>.[ps1|sh|...]
    └── *-skill.md
```

- **Path to run a script:** `scripts/<function_name>/<script_file>`  
  Example: `scripts/limit-order-any/limit-order-any.ps1`

- **Skill file:** Each function folder contains a `*-skill.md` that documents:
  - When to use the script
  - Parameters and required/optional flags
  - Step-by-step flow (order matters)
  - Examples and agent guidance

---

## How to use (humans)

1. **Prerequisites:** [Speed-CLI installed and configured](https://www.npmjs.com/package/@lightspeed-cli/speed-cli) (`speed setup`, `speed whoami`, `speed doctor`).
2. **Discover scripts:** List folders under `scripts/`; each folder name is an advanced function (e.g. `limit-order-any`).
3. **Run a script:** Execute the script in that folder (e.g. PowerShell: `.\scripts/limit-order-any/limit-order-any.ps1 -Chain base -Token speed -Amount 0.001 -TargetPct 5`).
4. **Learn syntax:** Open the `*-skill.md` in the same folder for parameters, flow, and examples.

---

## How to use (AI / agents)

For reliable, structured access:

1. **List available scripts:** Enumerate directory names under `scripts/` (e.g. `limit-order-any`). Each name is one advanced function.
2. **Get syntax and flow:** For each function you need, read the **skill file** in that folder: `scripts/<function_name>/*-skill.md`. The skill file is the source of truth for:
   - When to invoke the script
   - Required and optional parameters
   - Execution flow (do not reorder steps)
   - Example invocations and edge cases
3. **Execute:** Run the script at `scripts/<function_name>/<script_file>` with the parameters described in the skill file. Prefer paths with forward slashes for compatibility.

Skill files use YAML frontmatter (`name`, `description`) and clear sections so agents can discover and apply them without parsing the script source. Use the skill when the user refers to the function by name, to "limit order", or to the script path.

---

## Available scripts

| Function          | Path                              | Description |
|------------------|------------------------------------|-------------|
| limit-order-any  | `scripts/limit-order-any/`         | Buy any token with ETH, poll, then sell when ETH return reaches target % (or after max iterations). Success = ETH in vs ETH out. |

Add new rows as you add script folders. Keep the skill file in the same folder as the script.

---

## Adding a new script

1. Create a folder: `scripts/<function-name>/`.
2. Add the runnable script (e.g. `.ps1`, `.sh`).
3. Add a `*-skill.md` in the same folder with:
   - YAML frontmatter: `name`, `description` (third person; include trigger terms).
   - Sections: When to use, Flow (ordered steps), Parameters (table), Examples, and optional Agent guidance.
4. Document the function in the "Available scripts" table above.

This keeps discovery (folder names), execution (script path), and semantics (skill file) in one place and compatible with AI tooling.
