const { enforcePostSuiteTerminationGuardrails } = require("./mix_runner");

module.exports = async function globalTeardown() {
  try {
    enforcePostSuiteTerminationGuardrails({
      context: "playwright global teardown"
    });
  } catch (error) {
    process.stderr.write(`${error.message || String(error)}\n`);
    process.exit(1);
  }
};
