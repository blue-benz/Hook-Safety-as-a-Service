import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  resolve: {
    alias: {
      "@hsaas/shared": resolve(__dirname, "../shared/src/index.ts"),
    },
  },
});
