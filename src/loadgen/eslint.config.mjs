import globals from "globals"
import pluginJs from "@eslint/js"
import tseslint from "typescript-eslint"

// One glob per extension: minimatch 3 under eslint cannot expand brace globs
// with the brace-expansion version package.json pins.
const sourceFiles = ["**/*.js", "**/*.mjs", "**/*.cjs", "**/*.ts"]

export default [
    { ignores: ["build"] },
    { files: sourceFiles },
    { languageOptions: { globals: globals.node } },
    pluginJs.configs.recommended,
    ...tseslint.configs.recommended,
]
