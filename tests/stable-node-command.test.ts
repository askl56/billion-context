import assert from "node:assert/strict";
import { test } from "node:test";
import { stableNodeCommand } from "../src/plugin-install.js";

test("stableNodeCommand: non-Cellar paths pass through unchanged", () => {
    assert.equal(stableNodeCommand("/usr/local/bin/node"), "/usr/local/bin/node");
    assert.equal(stableNodeCommand("/usr/bin/node"), "/usr/bin/node");
    assert.equal(stableNodeCommand("/n/versions/node/v22.0.0/bin/node"), "/n/versions/node/v22.0.0/bin/node");
});

test("stableNodeCommand: Homebrew plain keg → prefix/bin/node (survives upgrades)", () => {
    assert.equal(
        stableNodeCommand("/opt/homebrew/Cellar/node/26.11.1/bin/node"),
        "/opt/homebrew/bin/node",
    );
    assert.equal(
        stableNodeCommand("/usr/local/Cellar/node/24.1.0/bin/node"),
        "/usr/local/bin/node",
    );
});

test("stableNodeCommand: versioned keg node@22 → prefix/opt/node@22/bin/node", () => {
    assert.equal(
        stableNodeCommand("/opt/homebrew/Cellar/node@22/22.1.1/bin/node"),
        "/opt/homebrew/opt/node@22/bin/node",
    );
});
