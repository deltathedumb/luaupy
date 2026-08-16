-- Roblox globals, for `luau-analyze`.
--
-- The open-source Luau binary knows nothing about Roblox, so every reference
-- to `game`, `workspace` or `Instance` in interop.luau reads as an unknown
-- global. They are real on the target and absent from the analyser, which is
-- exactly what a definition file is for.
--
-- Typed `any` on purpose. A real Roblox type definition set is enormous, moves
-- every week, and would make this file a dependency to maintain -- while the
-- thing being checked here is the runtime's own logic, not whether a Roblox
-- method was spelled right.
declare game: any
declare workspace: any
declare script: any
declare Instance: any
declare Enum: any
declare task: any
declare Vector3: any
declare Vector2: any
declare CFrame: any
declare Color3: any
declare UDim: any
declare UDim2: any
declare Ray: any
declare BrickColor: any
declare Random: any
declare Region3: any
declare TweenInfo: any
declare NumberRange: any
declare ColorSequence: any
declare NumberSequence: any
declare function warn(...: any): ()
declare function loadstring(src: string, chunkname: string?): (any, string?)
