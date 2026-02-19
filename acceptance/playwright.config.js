// @ts-check
const { defineConfig } = require("@playwright/test");

const serialized =
  /^(1|true|yes|on)$/i.test(process.env.MOM_ACCEPTANCE_SERIALIZED || "") ||
  (process.env.MOM_ACCEPTANCE_BUILD_MODE || "").toLowerCase() === "serialized";

module.exports = defineConfig({
  testDir: "./tests",
  fullyParallel: !serialized,
  workers: serialized ? 1 : undefined,
  reporter: "list"
});
