import { defineConfig } from "eslint/config"
import globals from "globals"
import js from "@eslint/js"
import tseslint from "typescript-eslint"
import pluginReact from "eslint-plugin-react"

// One glob per extension: minimatch 3 under eslint cannot expand brace globs
// with the brace-expansion version package.json pins.
const sourceFiles = [
    "**/*.js",
    "**/*.mjs",
    "**/*.cjs",
    "**/*.ts",
    "**/*.jsx",
    "**/*.tsx",
]

export default defineConfig([
    { files: sourceFiles },
    {
        files: sourceFiles,
        languageOptions: { globals: globals.browser },
    },
    {
        files: sourceFiles,
        plugins: { js },
        extends: ["js/recommended"],
    },
    tseslint.configs.recommendedTypeChecked,
    {
        languageOptions: {
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
        },
    },
    pluginReact.configs.flat.recommended,
    pluginReact.configs.flat["jsx-runtime"],
    {
        rules: {
            "@typescript-eslint/no-deprecated": "warn",
            "@typescript-eslint/only-throw-error": "off",
            "@typescript-eslint/no-unsafe-assignment": "off",
        },
    },
    {
        settings: {
            react: {
                version: "detect", // Automatically detect the React version
            },
        },
    },
])
