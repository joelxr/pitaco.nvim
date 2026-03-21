local fewshot = {
	messages = {
		{
			role = "user",
			content = [[
01 async function loadProfile(userId) {
02     const response = await fetch(`/api/users/${userId}`);
03     const data = await response.json();
04     return {
05         id: data.id,
06         name: data.name.trim(),
07         email: data.email.toLowerCase(),
08     };
09 }]],
		},
		{
			role = "assistant",
			content = [[
line=3: `response.json()` is called unconditionally. If the request fails with a non-JSON body or a 204/500 response, this throws before the caller can handle the HTTP failure.
line=6: `data.name.trim()` will throw when the API omits `name` or returns `null`, so a partial response turns into an unhandled runtime error.
line=7: `data.email.toLowerCase()` has the same nullability problem and will crash on missing or null email fields.]],
		},
		{
			role = "user",
			content = [[
10 function updateCache(cache, key, value) {
11     if (!cache[key]) {
12         cache[key] = [];
13     }
14
15     if (cache[key].length > 100) {
16         cache[key].shift();
17     }
18
19     cache[key].push(value);
20 }]],
		},
		{
			role = "assistant",
			content = [[
line=15: The size check runs before the new value is inserted, so when the array already has 100 items this code keeps all 101 entries instead of enforcing the advertised cap.
line=11: Using `!cache[key]` conflates "missing entry" with any falsy stored value. If this map ever contains non-array falsy values, the function silently overwrites them and corrupts the cache shape.]],
		},
		{
			role = "user",
			content = [[
21 function attachResizeListener(panel, onResize) {
22     window.addEventListener("resize", () => {
23         onResize(panel.getBoundingClientRect().width);
24     });
25 }]],
		},
		{
			role = "assistant",
			content = [[
line=22: This registers a new anonymous `resize` listener but never returns a way to remove it. Repeated mounts will leak listeners and trigger duplicate callbacks after each re-render.
line=23: The callback dereferences `panel` on every resize without checking whether the element is still mounted, which can crash if the listener fires after the panel has been removed.]],
		},
		{
			role = "user",
			content = [[
30 function buildUserIndex(users) {
31     const index = {};
32     for (const user of users) {
33         index[user.id] = user;
34     }
35     return index;
36 }
37
38 const usersById = buildUserIndex([{ id: 0, name: "A" }]);
39 console.log(usersById[0].name);]],
		},
		{
			role = "assistant",
			content = [[
line=33: Writing into a plain object with untrusted `user.id` values can clobber special keys like `__proto__`, which makes the index vulnerable to prototype pollution. Use `Object.create(null)` or a `Map` for this lookup table.]],
		},
		{
			role = "user",
			content = [[
40 async function saveSettings(api, settings) {
41     api.post("/settings", settings);
42     return { ok: true };
43 }]],
		},
		{
			role = "assistant",
			content = [[
line=41: The POST request is not awaited, so `saveSettings` reports success before the network call finishes. Callers can continue under the assumption that settings were saved even if the request later rejects.]],
		},
	},
}

return fewshot
