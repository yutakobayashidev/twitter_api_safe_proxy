import fs from "node:fs";
import vm from "node:vm";
import { expect, it } from "vitest";

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
it("legacy getter definitions retain liveness and become configurable", async () => {
	let value = 7;
	const { require } = await harness({
		1(_module, exports, require) {
			require.d(exports, { answer: () => value });
		},
	});
	const exports = require(1);
	expect(exports.answer).toBe(7);
	value = 9;
	expect(exports.answer).toBe(9);
	expect(Object.getOwnPropertyDescriptor(exports, "answer").configurable).toBe(true);
	expect(require.d).toBe(defineExports);
});
it("flat array getters support getPlaceholder name", async () => {
	const { require } = await harness({
		1(_module, exports, require) {
			require.d(exports, ["getPlaceholder", () => "ready", "other", () => 12]);
		},
	});
	expect(require(1).getPlaceholder).toBe("ready");
	expect(require(1).other).toBe(12);
});
it("flat array constants preserve data descriptors and mixed entries", async () => {
	const { require } = await harness({
		1(_module, exports, require) {
			require.d(exports, ["constant", 0, 42, "getter", () => 5, "zero", 0, 0]);
		},
	});
	const exports = require(1);
	expect(exports.constant).toBe(42);
	expect(exports.getter).toBe(5);
	expect(exports.zero).toBe(0);
	const descriptor = Object.getOwnPropertyDescriptor(exports, "constant");
	expect(descriptor.writable).toBe(false);
	expect(descriptor.configurable).toBe(true);
	expect(descriptor.get).toBe(undefined);
});
it("existing own export is preserved", async () => {
	const { require } = await harness({
		1(_module, exports, require) {
			Object.defineProperty(exports, "existing", { value: 11, enumerable: true });
			require.d(exports, ["existing", () => 22, "fresh", () => 33]);
		},
	});
	expect(require(1).existing).toBe(11);
	expect(require(1).fresh).toBe(33);
});
it("nested factories restore wrapper then original helper", async () => {
	let innerHelper;
	const { require } = await harness({
		1(_module, exports, require) {
			const wrapper = require.d;
			expect(require(2).value).toBe(2);
			expect(require.d).toBe(wrapper);
			require.d(exports, ["value", () => 1]);
		},
		2(_module, exports, require) {
			innerHelper = require.d;
			require.d(exports, ["value", 0, 2]);
		},
	});
	expect(require(1).value).toBe(1);
	expect(innerHelper).not.toBe(defineExports);
	expect(require.d).toBe(defineExports);
});
it("factory errors restore original helper", async () => {
	const { require } = await harness({
		1() {
			throw new Error("factory failure");
		},
	});
	expect(() => require(1)).toThrow(/factory failure/);
	expect(require.d).toBe(defineExports);
});
it("client constructor interception and bridge dispatch work", async () => {
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
	expect(Wrapped).not.toBe(Client);
	const client = new Wrapped();
	await startup;
	expect(await context.elonmusk_114514_request({ property: "dispatch", query: ["test"] })).toBe("response:test");
	expect(client).toBeInstanceOf(Client);
	expect(require.d).toBe(defineExports);
});
