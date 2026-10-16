# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Per-frame pose/override/visibility rules duplicated across draw plan, merged geometry and renderer

+++
status: closed
priority: medium
kind: task
labels: architecture, refactor, effort:l
depends: 5
created: 2026-10-14T15:57:38Z
updated: 2026-10-14T16:08:19Z
closed: 2026-10-14T16:08:19Z
+++

The rules for resolving a batch's material each frame (overrides, pose.materialUniforms, hasTangents/hasNormals, point/line unlit), node visibility, and mirroring (simd_determinant winding split) are reimplemented in PBRDrawPlan.init, PBRMergedGeometry (instances(pose:), visibility, materials, resources, material(of:overrides:), canMerge) and PBRRenderer (draw, morphedDraw, instances(of:)). The merged and per-batch paths can drift: e.g. the per-batch path splits mirrored/unmirrored ranges while the merged path bails to nil; transmissive classification must agree between canMerge and stage filtering. Testing it requires loading glTF fixtures in MetalSprocketsGLTF (DrawPlanTests, SkinningTests, MaterialOverrideTests).

Constraint: existing public API (PBRScene, PBRRenderer, PBRTransmissionPass, PBRMergedGeometry, PBRModel, etc.) must keep source compatibility for current users; any change is internal or additive, with deprecations rather than removals.

- `2026-10-14T16:08:19Z`: Shared per-frame rules now live in PBRFrameRules.swift (node placement, posed bounds, animated/overridden material resolution, mirroring) and are used by PBRDrawPlan, PBRMergedGeometry, PBRModel, PBRModelBuilder, PBRRenderer and PBRTransmissionPass. Two drifts fixed: merged visibility now culls records whose instances are all hidden (as per-batch did), and bounds of instances on nodes the pose doesn't cover match where they're drawn (identity) instead of being empty and culled. No public API changed.

---

## 2: Multi-model and stereo orchestration configured by mutating PBRRenderer internal flags

+++
status: closed
priority: medium
kind: task
labels: architecture, refactor, effort:m
depends: 5
created: 2026-10-14T15:57:38Z
updated: 2026-10-14T16:11:50Z
closed: 2026-10-14T16:11:50Z
+++

PBRScene, PBRImmersiveScene and PBRTransmissionPass build PBRRenderer values then mutate internal flags (phase, prePassStage, stereo, drawsTrianglesOnly, usesMergedGeometry, additionalRenderers). The 'first renderer directly, rest via ForEach' pattern is repeated three times. Blended batches are sorted twice (across items in PBRScene.blendedRuns, then within each PBRDrawPlan). PBRScene and PBRImmersiveScene duplicate transmission-pass and renderer setup. Pass ordering behaviour (cross-model blending, transmission stages) has no single place to test.

Constraint: existing public API (PBRScene, PBRRenderer, PBRTransmissionPass, PBRMergedGeometry, PBRModel, etc.) must keep source compatibility for current users; any change is internal or additive, with deprecations rather than removals.

- `2026-10-14T16:11:50Z`: PBRScene, PBRImmersiveScene and PBRTransmissionPass now build renderers through internal copy-builders (drawing(_:), prePass(_:), viewing(_:)) and an internal PBRTransmissionPass(renderers:target:showsBackground:) init; the first-direct-then-ForEach pattern is PBRRenderer.all(_:). Blended batches were not actually double-sorted: a .blended(order) plan keeps the given order (now commented). PBRImmersiveScene now uses the cheaper list pattern, and its pre-pass's first renderer gets the same configuration as the rest (drawsTrianglesOnly, debugView). Public properties unchanged.

---

## 3: Render target caches duplicate texture creation and invalidation logic

+++
status: closed
priority: low
kind: task
labels: architecture, refactor, effort:s
depends: 5
created: 2026-10-14T15:57:38Z
updated: 2026-10-14T16:15:48Z
closed: 2026-10-14T16:15:48Z
+++

PBRUpscaleTargetCache, PBRTransmissionTargetCache and PBRTransmissionTarget (lazy locked backdrop, clearing/loading descriptors) each repeat texture descriptor setup, size clamping and recreate-on-key-change logic. Pixel format and reverse-Z depth conventions are spread across them and PBRScene.upscaledPasses. None of this is tested.

Constraint: existing public API (PBRScene, PBRRenderer, PBRTransmissionPass, PBRMergedGeometry, PBRModel, etc.) must keep source compatibility for current users; any change is internal or additive, with deprecations rather than removals.

- `2026-10-14T16:15:48Z`: Texture creation, size clamping and recreate-on-change logic now live in PBRRenderTargets.swift (PBRTargetSize, MTLDevice.makeTargetTexture, PBRKeyedCache). PBRUpscaleTargetCache, PBRTransmissionTargetCache, PBRTransmissionTarget (incl. backdrop) and OffscreenRenderer.hdr use them. Caches moved out of PBRScene.swift with the same internal API. Added RenderTargetTests.

---

## 4: Merged pipeline parameter binding is hand-enumerated per prebuilt-vs-per-frame combination

+++
status: closed
priority: low
kind: task
labels: architecture, refactor, effort:s
depends: 5
created: 2026-10-14T15:57:38Z
updated: 2026-10-14T16:19:51Z
closed: 2026-10-14T16:19:51Z
+++

PBRRenderer.mergedInputs/mergedMaterials/mergedResources choose between a prebuilt buffer and per-frame values for each parameter by hand (including a 4-way switch on instances/materials), and mergedPipeline vs skinnedMergedPipeline duplicate setup. Shader parameter names are string literals that must match PBR.metal with no check.

Constraint: existing public API (PBRScene, PBRRenderer, PBRTransmissionPass, PBRMergedGeometry, PBRModel, etc.) must keep source compatibility for current users; any change is internal or additive, with deprecations rather than removals.

- `2026-10-14T16:19:51Z`: Merged pipelines now share one mergedPipeline(_:vertexShader:vertexDescriptor:...) builder that binds the common record inputs; prebuilt-vs-per-frame choice is one Element.parameter(_:values:else:) helper instead of the 4-way switch and two near-identical functions. Added ShaderParameterNameTests: every .parameter("name") bound in Swift must be a [[...]] argument in the package's Metal sources. Also fixed order-dependent DrawPlanTests from #1 (record order follows material identity).

---

## 5: Package has no test target; internals are only tested from MetalSprocketsGLTF

+++
status: closed
priority: high
kind: task
labels: testing, effort:m
created: 2026-10-14T15:57:38Z
updated: 2026-10-14T16:04:26Z
closed: 2026-10-14T16:04:26Z
+++

MetalSprocketsPBR has no Tests directory. Tests of its internals (PBRDrawPlan, merged geometry, skinning, material overrides) live in ../MetalSprocketsGLTF/Tests and depend on glTF loading. Changes to this package cannot be verified from within it.

- `2026-10-14T16:04:26Z`: Added MetalSprocketsPBRTests (Swift Testing): draw plan merging, culling, posing/mirroring fallback, hidden nodes, overrides, transmission stages, blended ordering, and PBRScene multi-item ordering, all with models built in code. Requires a Metal device.

---

## 6: Opaque batch order varies between runs for the same model

+++
status: closed
priority: low
kind: bug
labels: effort:s
created: 2026-10-14T16:21:04Z
updated: 2026-10-14T16:25:49Z
closed: 2026-10-14T16:25:49Z
+++

PBRModelBuilder.build() sorts opaque instances by ObjectIdentifier(material), which is a memory address. The same model built twice can get a different opaque batch order, so batch IDs, merged record order and draw order are not reproducible across runs.

Observed: DrawPlanTests that indexed records/batches by position (expecting node 0 first) failed intermittently until rewritten to look up by node.

Expected: building the same input gives the same batch order every time (helps GPU capture comparison, golden images and tests).

- `2026-10-14T16:25:49Z`: Opaque instances are now grouped by material in first-use order, then by insertion order, instead of by material address. Regression test ModelBuilderOrderTests.

---

## 7: README geometry example uses a PBRGeometryBuilder API that does not exist

+++
status: closed
priority: low
kind: documentation
labels: effort:xs
created: 2026-10-14T16:21:04Z
updated: 2026-10-14T16:22:25Z
closed: 2026-10-14T16:22:25Z
+++

README Usage step 1 calls geometry.add(.init(vertices: vertices, indices: indices)). PBRGeometryBuilder only has add(attributes:indices:primitiveType:morphTargets:label:) and add(_ mesh: MetalMesh). The example does not compile as written.

- `2026-10-14T16:22:25Z`: README example now uses add(attributes:indices:); ReadmeExampleTests runs the same code.

---

## 8: Add golden image tests and use one as the README screenshot

+++
status: closed
priority: low
kind: enhancement
labels: effort:m, area:testing
created: 2026-10-14T19:07:32Z
updated: 2026-10-15T16:18:16Z
closed: 2026-10-15T16:18:16Z
+++

PBR has no pixel tests, and the README has no image.

Add golden image tests with the GoldenImage package (github.com/schwa/GoldenImage), like MetalSprocketsGLTF's GoldenImageTests:
- Render scenes built in code (for example the README example, plus a grid of spheres with different metallic and roughness values) through OffscreenRenderer.
- Store the goldens in Tests/MetalSprocketsPBRTests/GoldenImages.
- Gate the suite with .requiresMetal4 so GitHub CI skips it; Buildkite runs it on real hardware.
- Use one golden (a larger render) as the README screenshot.

- `2026-10-15T16:00:53Z`: Related: #12 (coverage work).

---

## 9: PBRBounds duplicates GeometryLite3D's BoundingBox3D

+++
status: closed
priority: medium
kind: task
labels: effort:m, area:geometry, refactor
created: 2026-10-15T14:35:26Z
updated: 2026-10-15T16:04:23Z
closed: 2026-10-15T16:04:23Z
+++

PBRBounds (Sources/MetalSprocketsPBR/PBRBounds.swift) re-implements BoundingBox3D from GeometryLite3D: same min/max, center, union, transformed(by:). PBRBounds adds .empty, isEmpty, and radius, which BoundingBox3D lacks (GeometryLite3D#22). The package now has two bounds types; PBRGeometryBuilder already constructs BoundingBox3D for SwiftMesh. Public API.

- `2026-10-15T16:00:53Z`: Related: #10, #11. Do this first.
- `2026-10-15T16:04:23Z`: Removed PBRBounds; BoundingBox3D (GeometryLite3D 0.2.2 has empty/isEmpty/radius/union) is used everywhere. Kept an internal transformedKeepingEmpty(by:) because BoundingBox3D.transformed(by:) turns empty bounds into NaN. Breaking change for MetalSprocketsGLTF (GLTFAsset.swift, PBRCompatibility.swift, 2 test files).

---

## 10: PBRFrustum duplicates GeometryLite3D's Frustum

+++
status: closed
priority: medium
kind: task
labels: effort:s, area:geometry, refactor
depends: 9
created: 2026-10-15T14:35:26Z
updated: 2026-10-15T16:05:24Z
closed: 2026-10-15T16:05:24Z
+++

PBRFrustum (Sources/MetalSprocketsPBR/PBRFrustum.swift) uses the same plane extraction and positive-vertex test as GeometryLite3D's Frustum. Differences: PBRFrustum takes PBRBounds, not BoundingBox3D, and reports empty bounds as not visible. Public API.

- `2026-10-15T16:05:24Z`: Removed PBRFrustum; Frustum from GeometryLite3D is used. Internal intersectsNonEmpty(_:) keeps 'empty bounds are never visible'. Breaking for callers of PBRMergedGeometry.visibility(frustums:) (now [Frustum]).

---

## 11: simd_float4x4 perspective/orthographic/lookAt helpers duplicate GeometryLite3D

+++
status: closed
priority: medium
kind: task
labels: effort:s, area:geometry, refactor
created: 2026-10-15T14:35:26Z
updated: 2026-10-15T16:20:44Z
closed: 2026-10-15T16:20:44Z
+++

PBRCamera.swift adds public simd_float4x4.perspective(fovY:aspectRatio:near:far:), .orthographic(halfWidth:halfHeight:near:far:), and .lookAt(eye:target:up:). GeometryLite3D has PerspectiveProjection (.reversed depth mode, same matrix), OrthographicProjection, and LookAt. The public float4x4 extensions can also collide with other packages in clients that import both.

- `2026-10-15T16:00:53Z`: Related: #9, #10. Helpers are now internal, so the client-collision concern no longer applies.
- `2026-10-15T16:02:57Z`: Checked replacing the helpers with GeometryLite3D's PerspectiveProjection(.reversed)/OrthographicProjection/LookAt. Punting: the extension is still public (not internal; my earlier triage comment was wrong) and MetalSprocketsGLTF depends on it — GLTFCamera.swift uses .perspective/.orthographic and ~20 GLTF test sites use .perspective/.lookAt, so removal is a cross-repo breaking change. Also OrthographicProjection takes halfHeight+aspect, so it cannot express glTF's independent xmag/ymag. Unblocker: OK to remove the public helpers and migrate MetalSprocketsGLTF in lockstep (and add a halfWidth/halfHeight ortho to GeometryLite3D, or keep an internal ortho helper)?
- `2026-10-15T16:20:44Z`: Removed the public simd_float4x4 perspective/orthographic/lookAt helpers (no deprecation). PBRCamera.framing and tests use GeometryLite3D's PerspectiveProjection(.reversed) and LookAt. Orthographic is removed with no replacement: GeometryLite3D's OrthographicProjection takes halfHeight + aspect and can't express glTF's independent xmag/ymag, so MetalSprocketsGLTF (GLTFCamera.swift) must build its own reversed-depth orthographic matrix. MetalSprocketsGLTF's tests must also move to PerspectiveProjection/LookAt. MaterialSpheres golden re-recorded (38 pixels changed by <=3 levels from LookAt's float rounding).

---

## 12: Raise unit test coverage to 100%

+++
status: closed
priority: medium
kind: task
labels: effort:l, area:testing
created: 2026-10-15T16:00:15Z
updated: 2026-10-15T16:29:26Z
closed: 2026-10-15T16:29:26Z
+++

Measure current coverage (xcb test with code coverage) and add tests until MetalSprocketsPBR and MetalSprocketsPBRShaders reach 100% line coverage. Note any code that cannot be tested headlessly (GPU/UI paths) and decide whether to exclude or restructure it.

- `2026-10-15T16:00:53Z`: Related: #8 (golden image tests cover GPU paths).
- `2026-10-15T16:15:02Z`: Coverage 49.0% -> 98.3% lines (2850/2898). Added RenderTests, MergedRenderTests (incl. stereo via a 2-slice offscreen target), EnvironmentTests, GeometryBuilderTests, ValueTests. Removed unused defaults (Primitive.hasNormals, BlendedRun.premultiplied) and VertexVariant's unused Identifiable. Remaining uncovered: (1) Metal/CG allocation-failure throws (PBRMaterial x3, PBRGeometryBuilder, PBRGeometryBuffers, PBRMergedGeometry, PBRModelBuilder, PBRRenderTargets, PBREnvironment Builder, PBRShaders.make, PBRHDROutput CGImage/EXR finalize); (2) PBREnvironment.studio fatalError and the shader-bundle-not-found exception; (3) shader bundle env-var override path (runs once per process); (4) PBRRenderer.swift hidden-skinned-mesh branch in draw(_:) — dead because hidden skinned batches get empty bounds and are culled first. Decision needed: exclude these from the 100% target, or remove the dead branch (4)?
- `2026-10-15T16:27:30Z`: Coverage now 98.5% (2832/2876). Removed the dead hidden-skinned branch in PBRRenderer.draw and tested PBREnvironmentBuilder's missing-kernel error (Builder made internal and renamed). Remaining uncovered lines are allocation/creation failures, studio fatalError, and the shader bundle fallbacks.
- `2026-10-15T16:29:26Z`: Closed at 98.5% line coverage. The remaining lines can't be tested: allocation/creation failures, the studio fatalError, and the shader bundle fallbacks.

---

## 13: Mark PBRRoomLighting.run() @concurrent

+++
status: closed
priority: medium
kind: task
labels: effort:xs, area:concurrency
created: 2026-10-15T16:54:29Z
updated: 2026-10-16T02:01:28Z
closed: 2026-10-16T02:01:28Z
+++

PBRRoomLighting.run() (Sources/MetalSprocketsPBR/PBRRoomLighting.swift:54) is a plain nonisolated async method. Each anchor update builds a PBREnvironment, which blocks on commandBuffer.waitUntilCompleted() (PBREnvironment.swift:184).

Today it runs on the global executor. If the package adopts NonisolatedNonsendingByDefault, it would inherit the caller actor: `.task { await lighting.run() }` in SwiftUI would block the main actor on GPU work.

Fix: declare it `@concurrent public func run() async`.

---

## 14: Per-light shadow input for the lighting shader

+++
status: closed
priority: medium
kind: feature
labels: effort:l, area:shading
created: 2026-10-15T19:43:47Z
updated: 2026-10-16T02:04:34Z
closed: 2026-10-16T02:04:34Z
+++

PBRLight has no shadow input, so a client cannot shadow one light's contribution without shadowing all of them. MetalSprocketsSceneGraph uses a screen-space mask after the PBR pass, which darkens every light at once: surfaces facing away from a shadowing light, or outside its category, get darker anyway (MSSG #102). Needs a way to pass a depth2d_array shadow map, per-slice view-projections and each light's slice range (start, count), and have the lighting loop scale each light's direct contribution by its own PCF result. MSSG's BlinnPhong.metal (sliceShadow, shadowSliceStart/Count on the light) is a working reference.

---

## 15: Per-material render state (blend, depth, color mask, fill mode)

+++
status: open
priority: low
kind: enhancement
labels: effort:m, area:rendering
created: 2026-10-16T01:59:14Z
updated: 2026-10-16T02:00:59Z
+++

PBRRenderer sets its own depth/stencil, blend and fill state. Callers cannot change these per material; only alphaMode and doubleSided are exposed. State set outside PBRRenderer is overridden.

Add PBRMaterial.renderState with blend mode, depth read/write, color write mask and fill mode. PBRRenderer applies it per batch.

Needed by MetalSprocketsSceneGraph #114 (PBRSceneMaterial.renderState).

- `2026-10-16T02:04:54Z`: Investigated PBRRenderer/PBRDrawPlan/PBRMergedGeometry. Fill mode and depth read/write can be set per draw on the encoder, but blend and color write mask are pipeline state, so per-material values need batches grouped into separate pipelines by render state, and merged geometry must exclude non-default states. Punting: needs design decisions. Questions: (1) Which blend modes (e.g. opaque/alpha/premultiplied/additive/multiply, or raw MTL blend factors)? (2) Does a non-default blend put the batch in the back-to-front sorted blended list, or keep it in place? (3) How should renderState interact with alphaMode (override, or alphaMode picks the default renderState)? (4) Is depth 'read' off = compare .always, and does stereo's forced blended depth write still win on visionOS?

---

## 16: PBRTransmissionPass cannot be built from existing renderers

+++
status: new
priority: low
kind: enhancement
created: 2026-10-16T02:06:06Z
+++

PBRTransmissionPass.init(renderers:target:showsBackground:) is internal. The public init takes a model and builds a new PBRRenderer, so the pass loses settings made on the caller's renderers (materialOverrides, several models in one target).

MetalSprocketsSceneGraph draws one PBRRenderer per batch, each with its own overrides and lights. Its transmission pre-pass therefore uses one combined model and ignores per-entry fades.

Expected: a public init that takes the renderers used for the main pass (e.g. make init(renderers:target:showsBackground:) public).

Needed by MetalSprocketsSceneGraph (transmission pre-pass, follow-up to #123).

---
