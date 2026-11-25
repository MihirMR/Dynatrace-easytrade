/// <reference types="vitest" />
import { mergeConfig, defineConfig } from "vite"

import viteConfig from "./vite.config"

export default defineConfig((configEnv) =>
    mergeConfig(
        viteConfig(configEnv),
        defineConfig({
            test: {
                globals: true,
                environment: "jsdom",
                testTimeout: 10000,
                // Lets tests import the shipped stylesheets with `?raw`.
                // Only main.tsx imports these sheets, and no test imports
                // main.tsx, so no other test sees a style change.
                css: { include: [/\/src\/styles\/[^/]+\.css(?:\?|$)/] },
            },
        })
    )
)
