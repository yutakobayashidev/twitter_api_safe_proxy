import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../setup.js", import.meta.url), "utf8");
function defineExports(exports, definition) {
	if (Array.isArray(definition)) {
		for (let index = 0; index < definition.length; ) {
			const name = definition[index++];
			const getter = definition[index++];
			const descriptor =
				getter === 0 ? { value: definition[index++], enumerable: true } : { get: getter, enumerable: true };
			if (!Object.hasOwn(exports, name)) Object.defineProperty(exports, name, descriptor);
		}
	} else {
		for (const name in definition) {
			if (Object.hasOwn(definition, name) && !Object.hasOwn(exports, name)) {
				Object.defineProperty(exports, name, { get: definition[name], enumerable: true });
			}
		}
	}
}
async function harness(factories) {
	const context = vm.createContext({ console: { log() {} } });
	context.window = context;
	const startup = vm.runInContext(source, context);
	const chunks = [];
	chunks.push = Array.prototype.push.bind(chunks);
	context.webpackChunk_twitter_responsive_web = chunks;
	await new Promise((resolve) => setImmediate(resolve));
	context.webpackChunk_twitter_responsive_web.push([[1], factories]);
	const cache = new Map();
	function require(id) {
		if (cache.has(id)) return cache.get(id).exports;
		const module = { exports: {} };
		cache.set(id, module);
		factories[id](module, module.exports, require);
		return module.exports;
	}
	require.d = defineExports;
	return { context, require, startup };
}
await test("legacy getter definitions retain liveness and become configurable", async () => {
	let value = 7;
	const { require } = await harness({
		1(_module, exports, require) {
			require.d(exports, { answer: () => value });
		},
	});
	const exports = require(1);
	assert.equal(exports.answer, 7);
	value = 9;
	assert.equal(exports.answer, 9);
	assert.equal(Object.getOwnPropertyDescriptor(exports, "answer").configurable, true);
	assert.equal(require.d, defineExports);
});
await test("flat array getters support getPlaceholder name", async () => {
	const { require } = await harness({
		1(_module, exports, require) {
			require.d(exports, ["getPlaceholder", () => "ready", "other", () => 12]);
		},
	});
	assert.equal(require(1).getPlaceholder, "ready");
	assert.equal(require(1).other, 12);
});
await test("flat array constants preserve data descriptors and mixed entries", async () => {
	const { require } = await harness({
		1(_module, exports, require) {
			require.d(exports, ["constant", 0, 42, "getter", () => 5, "zero", 0, 0]);
		},
	});
	const exports = require(1);
	assert.equal(exports.constant, 42);
	assert.equal(exports.getter, 5);
	assert.equal(exports.zero, 0);
	const descriptor = Object.getOwnPropertyDescriptor(exports, "constant");
	assert.equal(descriptor.writable, false);
	assert.equal(descriptor.configurable, true);
	assert.equal(descriptor.get, undefined);
});
await test("existing own export is preserved", async () => {
	const { require } = await harness({
		1(_module, exports, require) {
			Object.defineProperty(exports, "existing", { value: 11, enumerable: true });
			require.d(exports, ["existing", () => 22, "fresh", () => 33]);
		},
	});
	assert.equal(require(1).existing, 11);
	assert.equal(require(1).fresh, 33);
});
await test("nested factories restore wrapper then original helper", async () => {
	let innerHelper;
	const { require } = await harness({
		1(_module, exports, require) {
			const wrapper = require.d;
			assert.equal(require(2).value, 2);
			assert.equal(require.d, wrapper);
			require.d(exports, ["value", () => 1]);
		},
		2(_module, exports, require) {
			innerHelper = require.d;
			require.d(exports, ["value", 0, 2]);
		},
	});
	assert.equal(require(1).value, 1);
	assert.notEqual(innerHelper, defineExports);
	assert.equal(require.d, defineExports);
});
await test("factory errors restore original helper", async () => {
	const { require } = await harness({
		1() {
			throw new Error("factory failure");
		},
	});
	assert.throws(() => require(1), /factory failure/);
	assert.equal(require.d, defineExports);
});
await test("client constructor interception and bridge dispatch work", async () => {
	class Client {
		get() {}
		post() {}
		delete() {}
		dispatch(value) {
			return `response:${value}`;
		}
	}
	const { require, context, startup } = await harness({
		1(_module, exports, require) {
			require.d(exports, ["Client", () => Client]);
		},
	});
	const Wrapped = require(1).Client;
	assert.notEqual(Wrapped, Client);
	const client = new Wrapped();
	await startup;
	assert.equal(await context.elonmusk_114514_request({ property: "dispatch", query: ["test"] }), "response:test");
	assert.ok(client instanceof Client);
	assert.equal(require.d, defineExports);
});
