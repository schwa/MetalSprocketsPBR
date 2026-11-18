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
status: closed
priority: low
kind: enhancement
labels: area:rendering, effort:l
created: 2026-10-16T01:59:14Z
updated: 2026-10-16T02:22:46Z
closed: 2026-10-16T02:22:46Z
+++

PBRRenderer sets its own depth/stencil, blend and fill state. Callers cannot change these per material; only alphaMode and doubleSided are exposed. State set outside PBRRenderer is overridden.

Add PBRMaterial.renderState with blend mode, depth read/write, color write mask and fill mode. PBRRenderer applies it per batch.

Needed by MetalSprocketsSceneGraph #114 (PBRSceneMaterial.renderState).

- `2026-10-16T02:04:54Z`: Investigated PBRRenderer/PBRDrawPlan/PBRMergedGeometry. Fill mode and depth read/write can be set per draw on the encoder, but blend and color write mask are pipeline state, so per-material values need batches grouped into separate pipelines by render state, and merged geometry must exclude non-default states. Punting: needs design decisions. Questions: (1) Which blend modes (e.g. opaque/alpha/premultiplied/additive/multiply, or raw MTL blend factors)? (2) Does a non-default blend put the batch in the back-to-front sorted blended list, or keep it in place? (3) How should renderState interact with alphaMode (override, or alphaMode picks the default renderState)? (4) Is depth 'read' off = compare .always, and does stereo's forced blended depth write still win on visionOS?

---

## 16: PBRTransmissionPass cannot be built from existing renderers

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs, area:rendering
created: 2026-10-16T02:06:06Z
updated: 2026-10-16T02:15:22Z
closed: 2026-10-16T02:15:22Z
+++

PBRTransmissionPass.init(renderers:target:showsBackground:) is internal. The public init takes a model and builds a new PBRRenderer, so the pass loses settings made on the caller's renderers (materialOverrides, several models in one target).

MetalSprocketsSceneGraph draws one PBRRenderer per batch, each with its own overrides and lights. Its transmission pre-pass therefore uses one combined model and ignores per-entry fades.

Expected: a public init that takes the renderers used for the main pass (e.g. make init(renderers:target:showsBackground:) public).

Needed by MetalSprocketsSceneGraph (transmission pre-pass, follow-up to #123).

---

## 17: Shadow intensity and color for per-light shadows

+++
status: closed
priority: medium
kind: enhancement
created: 2026-10-16T02:39:16Z
updated: 2026-10-16T12:06:44Z
closed: 2026-10-16T12:06:44Z
+++

PBRShadows (#14) scales a shadowed light's direct contribution by the full PCF result. Callers cannot set how strongly shadows darken or what color they tint.

MetalSprocketsSceneGraph's SceneGraphShadows has intensity (0 leaves shadowed pixels unchanged, 1 fully shadows; default 0.6) and color (like SCNLight.shadowColor). Its Blinn-Phong shader applies both per light. If PBR switches to in-shader shadows, it loses both.

Expected: PBRShadows gains intensity and color, applied per light in lightShadow: contribution *= mix(1, mix(color, 1, lit), intensity), or the same formula as MetalSprocketsSceneGraph's BlinnPhong.metal.

Needed by MetalSprocketsSceneGraph #102.

---

## 18: PBRTransmissionPass cannot draw non-PBR content

+++
status: closed
priority: low
kind: enhancement
created: 2026-10-16T12:15:55Z
updated: 2026-10-16T12:20:16Z
closed: 2026-10-16T12:20:16Z
+++

PBRTransmissionPass draws only its PBRRenderers (and the environment background) into the transmission target. Callers that mix renderers cannot add their own opaque content. Glass then refracts only the PBR part of the scene.

MetalSprocketsSceneGraph draws Blinn-Phong and ShaderMaterial meshes with its own renderers. These meshes are missing behind PBR glass.

Expected: an optional element (for example additionalContent: AnyElement?) drawn in the 'PBR Transmission Scene' render pass after the PBR renderers. It uses the same target, reversed depth and view amplification. The caller is responsible for linear (not tone-mapped) output.

Needed by MetalSprocketsSceneGraph #129.

---

## 19: PBRTransmissionPass.additionalContent should be generic, not AnyElement

+++
status: closed
priority: low
kind: enhancement
created: 2026-10-16T12:20:08Z
updated: 2026-10-16T12:36:43Z
closed: 2026-10-16T12:36:43Z
+++

PBRTransmissionPass.additionalContent is AnyElement?. Type erasure hides the content type from the element system and makes callers wrap their content in AnyElement(...).

Expected: make PBRTransmissionPass generic over the content type (for example PBRTransmissionPass<AdditionalContent: Element>), with an init that takes a @ElementBuilder closure. Keep the current inits through a constrained extension (for example AdditionalContent == EmptyElement), so existing callers do not change.

Follow-up to #18.

---

## 20: Explore RoboCloth cloth materials

+++
status: open
priority: low
kind: feature
labels: effort:m, area:shading, deferred
created: 2026-10-23T13:52:04Z
updated: 2026-11-17T13:27:29Z
+++

RoboCloth (https://github.com/theialab/robocloth, local copy in ~/Projects/Vendor) has 500 captured cloth materials. They are released as neural BRDFs (a 16-channel latent texture plus a shared MLP) and as a Disney PBR fit.

Findings:
- Checkpoints: HF `theialab/RoboCloth-assets`, `checkpoints/stage2/RoboCloth/<material>/PBR_epoch*.ckpt`.
- Licenses: code Apache-2.0; dataset and checkpoints CC BY 4.0 (attribution needed).
- PBR latent layout (`rendering/brdf_plugin/material/anisotropic_pbr.py`): [0:12] baseColor(3), ao, roughness, metallic, ior, aniso_strength, aniso_rot, specularTint, sheen, sheenTint; [12:28] neural-geometry latent; [28:34] predicted normal(3) + tangent(3). 2048² texture.

Option 1 (do first, effort:m): bake the PBR fit.
- uv script: load the checkpoint, decode the latent with the same activations/ranges as `PBRDecoder`, write base color, ORM, anisotropy, sheen and normal maps.
- Map Disney sheen/sheenTint to glTF sheen color/roughness. Check that anisotropy rotation and the tangent frame match our conventions.
- This is an approximation: the neural-geometry UV-offset MLP cannot be baked.

Option 2 (research, effort:l-xl): neural BRDF fragment shader.
- MLP weights in a buffer, latent in 4 RGBA16F textures, about 200K MACs per light sample.
- No pre-filtered IBL: needs many env samples or an analytic ambient fallback.
- A separate material type outside the glTF model.

Verify: compare against their Mitsuba renders (cloth_on_bar).

---

## 21: Keep the sampler descriptor with each PBRMaterial.Binding

+++
status: closed
priority: low
kind: enhancement
labels: effort:s, area:shading
created: 2026-10-24T11:53:22Z
updated: 2026-10-24T11:56:48Z
closed: 2026-10-24T11:56:48Z
+++

PBRMaterial.Binding holds an MTLSamplerState, which cannot be read back. SceneSprockets saves scenes to disk (SceneSprockets #180) and needs each texture's filters and address modes. Keep the MTLSamplerDescriptor (or a small Codable sampler description) next to the sampler state. Today SceneSprockets loads every texture with linear repeat.

---

## 22: PBRTransmissionPass: first pass has no queue barrier, races the previous frame

+++
status: closed
priority: high
kind: bug
labels: effort:xs
created: 2026-10-25T15:44:32Z
updated: 2026-10-25T15:44:49Z
closed: 2026-10-25T15:44:49Z
+++

Found from SceneSprockets #242 (pink garbage frames while orbiting a scene with transmissive materials, much worse in Debug and when SwiftUI is busy). A GPU capture shows that every pass in a frame starts with a Metal 4 queue barrier except 'PBR Transmission Scene'. That pass clears and re-renders the PBRTransmissionTarget color and depth textures, which are the same textures every frame. Metal 4 does not order work across submissions on a queue, so the clear can overlap the previous frame's main pass (fragment shaders sampling the transmission texture) and its mipmap and backdrop blits. Fix: QueueBarrier(after: [.fragment, .blit], before: .fragment) at the start of the pass.

---

## 23: PBRMaterial requires an MTLDevice at construction

+++
status: closed
priority: medium
kind: enhancement
created: 2026-11-10T17:45:41Z
updated: 2026-11-10T17:50:18Z
closed: 2026-11-10T17:50:18Z
+++

`PBRMaterial.init(name:uniforms:doubleSided:textureBindings:device:)` builds `resourceBuffer` immediately. `PBRMaterial.Binding.init(texture:samplerDescriptor:device:)` and `placeholderBinding(device:)` build `MTLSamplerState`s and placeholder textures immediately. So a material (even one with only uniform values and no textures) cannot exist without a device.

Downstream (SceneSprockets #355, #358, #359, #360) wants scene construction to be device-free, with GPU resources made later by the RenderView that draws the scene. Because `PBRMaterial` has no device-independent form, every material has to be given a device when it is built.

- `2026-11-10T17:50:18Z`: Won't fix: PBRMaterial is a GPU type and is meant to need a device.

---

## 24: No way to apply screen-space ambient occlusion to only the indirect lighting

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-11-12T03:34:27Z
updated: 2026-11-16T22:44:30Z
closed: 2026-11-16T22:44:30Z
+++

The PBR shader has one source of ambient occlusion: the material's occlusion texture (`occlusionTexture`, scaled by `occlusionStrength`), which multiplies the image-based / indirect lighting.

A renderer that computes screen-space ambient occlusion (SSAO) has no way to give that per-pixel value to the PBR shader. Its only option is to darken the finished frame after shading, which also darkens direct lighting, emission and specular highlights, so occluded areas go darker than they should and lit creases lose their highlights.

Expected: a renderer can supply a screen-space occlusion value per pixel that multiplies only the indirect (ambient / image-based) terms, combined with the material's occlusion texture.

Reported from SceneSprockets #136 (SceneSprockets' ambient occlusion is a post-process that darkens the final lit color).

---

## 25: Own PBRStereoViews duplicates other packages' stereo view types

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-11-12T20:42:20Z
updated: 2026-11-12T20:54:59Z
closed: 2026-11-12T20:54:59Z
+++

PBRStereoViews is this package's own copy of per-view stereo matrices, viewports and vertex amplification setup. MetalSprocketsAddOns, MetalSprocketsPBR, MetalSprocketsParticles and SceneSprockets each have one, and callers convert between them at every boundary. See MetalSprockets #MetalSprockets#558.

## Proposed fix (per schwa)

Once MetalSprockets ships a shared StereoViews (#MetalSprockets#558) in a tagged release, adopt it in place of PBRStereoViews and bump the MetalSprockets dependency.

---

## 26: Surfaces that build their own Fragment cannot get the frame bindings

+++
status: closed
priority: medium
kind: feature
created: 2026-11-17T02:32:02Z
updated: 2026-11-17T02:54:37Z
closed: 2026-11-17T02:54:37Z
+++

PBRLighting.h lets other shaders call PBR::shade, but the Swift side that fills its inputs is private to PBRRenderer: PBRFrameUniforms setup, the lights array, environment textures and sampler, shadow uniforms and map, ambient occlusion, and the placeholder textures for when there is no shadow map, transmission scene, or occlusion. Another renderer has to copy that code to call PBR::shade, and its result drifts from PBR meshes.

PBRMaterialUniforms.resolved and PBRMaterial.resourceBuffer are also internal, so a PBRMaterial cannot be bound for such a shader.

Seen in SceneSprocketsAddOns #41 and #45.

---

## 27: Environment builds block the calling thread until the GPU finishes

+++
status: closed
priority: low
kind: enhancement
labels: effort:s, area:concurrency
created: 2026-11-17T13:24:34Z
updated: 2026-11-17T13:36:08Z
closed: 2026-11-17T13:36:08Z
+++

Building a PBREnvironment waits synchronously for its GPU work (commandBuffer.waitUntilCompleted() in PBREnvironment.swift).

Two places this lands on a thread that should not block:

- PBRRoomLighting.receiveUpdates builds an environment per probe update inside an async function, so each rebuild blocks a cooperative-pool thread for the whole prefilter. Throttled by minimumInterval (default 1 s), one at a time.
- PBREnvironment.studio is built on first access. It is the default argument of PBRLighting.init, so the first PBRLighting() often builds it on the main thread.

Expected: environment builds do not block a cooperative-pool thread or the main thread.

No measured hitch or starvation yet; found by code review.

- `2026-11-17T13:36:08Z`: Room lighting no longer blocks a Swift concurrency thread: rebuilds go through an internal async PBREnvironment.build(cube:...) that runs the GPU-waiting build on a serial dispatch queue and resumes a continuation. The studio part needs a public API change, so it is split out as #35. The PBRRoomLighting change is visionOS-only and was not compiled (xcb builds this package for macOS only); the async build itself is covered by EnvironmentTests.cubeEnvironmentAppliesScale.

---

## 28: PBRShadows and PBRAmbientOcclusion are @unchecked Sendable with no stated reason

+++
status: closed
priority: low
kind: task
labels: effort:xs, area:concurrency
created: 2026-11-17T13:24:34Z
updated: 2026-11-17T13:36:17Z
closed: 2026-11-17T13:36:17Z
+++

In PBRLighting.swift, PBRShadows and PBRAmbientOcclusion are declared @unchecked Sendable without a comment saying why that is safe. Every other @unchecked Sendable and nonisolated(unsafe) in the package states its justification.

Expected: each unchecked conformance says why it is safe.

No known race; found by code review.

- `2026-11-17T13:36:17Z`: Added comments stating why each @unchecked Sendable is safe.

---

## 29: Per-batch draw decisions are made in PBRRenderer, not PBRDrawPlan

+++
status: closed
priority: medium
kind: task
labels: architecture, refactor, effort:l, area:rendering
created: 2026-11-17T13:26:30Z
updated: 2026-11-17T13:31:27Z
closed: 2026-11-17T13:31:27Z
+++

PBRDrawPlan says planning is pure and the renderer only turns a plan into elements. That holds for merged draws. For per-batch draws the plan only groups batches; PBRRenderer.draw, morphedDraw and instances(of:) decide the rest inside element code:

- hidden-node filtering, and the unmirrored/mirrored instance ranges with their winding
- cull mode per transmission pre-pass stage, and fill mode
- unlit points and lines, and the drawsTrianglesOnly skip
- morph weight fallback (pose, else the node's rest weights)

The merged path makes the equivalent decisions in the plan (visible, doubleSided, instances), so the two paths decide the same things in different layers. #1 moved the shared rules into PBRFrameRules.swift but left where they are applied split.

These per-batch decisions cannot be asserted in DrawPlanTests; they are only reachable through GPU renders (RenderTests, MergedRenderTests).

Suspected, not verified: the plan does not know about drawsTrianglesOnly, so an opaque group or blended run holding only point or line batches still gets a pipeline whose draws are all skipped.

Constraint: no public API changes.

Found by code review; nothing here was built or run.

- `2026-11-17T13:27:19Z`: Related: #30 (frame composition builds on the per-batch plan).
- `2026-11-17T13:31:27Z`: PBRDrawPlan now builds a BatchDraw per per-batch draw (material, resolved uniforms, cull/fill mode, winding ranges, posed instances, joint matrices, morph weights); PBRRenderer only encodes it. drawsTrianglesOnly is a plan input, so point/line batches are left out and groups/runs holding only them get no pipeline (confirms the suspected empty pipeline). Batches with every instance hidden are dropped from the plan. New DrawPlanTests cover winding ranges, cull modes and the triangles-only filter.

---

## 30: Frame composition across models is spread over PBRScene, PBRImmersiveScene, PBRTransmissionPass and PBRRenderer flags

+++
status: closed
priority: medium
kind: task
labels: architecture, refactor, effort:l, area:rendering
created: 2026-11-17T13:26:31Z
updated: 2026-11-17T13:33:59Z
closed: 2026-11-17T13:33:59Z
+++

One frame with several models, a transmission pre-pass or stereo is planned by copying and reconfiguring PBRRenderer values (drawing, prePass, viewing). What remains after #2:

- PBRScene.blendedRuns repeats PBRDrawPlan's posed-bounds and distance-to-camera computation for blended batches.
- The decision to make a transmission target (a model has transmission and the debug view is lit) is written in both PBRScene.content and PBRImmersiveScene.body.
- PBRTransmissionPass.content rescans every batch of every renderer for hasBackFaces instead of reading it from a plan.
- Each renderer copy builds its own PBRFrameBindings and PBRDrawPlan; with several items, a renderer is made per opaque phase, per blended run and again for the pre-pass stages.

Pass and draw order across items, stereo and pre-pass stages has no single value to test; the four scene tests at the end of DrawPlanTests check pieces of it.

Suspected, not verified: in stereo with several items, an item's transmissive batches drawn as coverage are drawn by that item's .opaque phase renderer and write depth, so they are drawn before later items' opaque batches, which are then depth-rejected behind that glass.

Constraint: no public API changes.

Found by code review; nothing here was built or run.

\- `2026-11-17T13:27:19Z`: Related: #29 (per-batch decisions in the plan), #31 (stereo resolution).
\- `2026-11-17T13:33:59Z`: Fixed: the suspected stereo bug is real and is fixed. With several items in stereo, transmissive batches drawn as coverage (which write depth) were drawn by their item's opaque-phase renderer, before later items' opaque batches. They now join the shared back-to-front order of the blended phase (DrawPhase.blended carries SortedBatch entries that mark coverage batches, since opaque and blended batch IDs overlap). Red-first test: SceneOrderingTests.stereoCoverageGlassDrawsAfterEveryItemsOpaqueBatches.

Also: posed bounds for sorting/culling are one rule (PBRModel.worldBounds(of:pose:modelMatrix:)) used by both PBRDrawPlan and PBRScene.blendedRuns; the transmission-pass decision is PBRScene.needsTransmissionPass, used by PBRScene and PBRImmersiveScene; the back-face rule is PBRMaterial.hasTransmissiveBackFaces, used by the plan and PBRTransmissionPass (which still scans batches rather than reading a plan, as the pass has no plan of its own).

Not done here: per-renderer PBRFrameBindings rebuilds, filed as a follow-up. PBRImmersiveScene compiles only for visionOS and xcb builds this package for macOS only, so that one-line change was not compiled.

---

## 31: Mono and stereo views are two representations that every element resolves itself

+++
status: closed
priority: low
kind: task
labels: architecture, refactor, effort:m, area:rendering
created: 2026-11-17T13:26:31Z
updated: 2026-11-17T13:38:23Z
closed: 2026-11-17T13:38:23Z
+++

PBRRenderer and PBREnvironmentBackground each hold viewMatrix and projectionMatrix plus an optional stereo, and each resolves 'stereo?.x ?? [mono]' itself (viewProjections, cameraPositions, inverse view-projections). PBRTransmissionPass and PBRImmersiveScene do the same through renderer.stereo.

- The 'between the eyes' camera average (cameraPositions.reduce(.zero, +) / count) is written in PBRRenderer.content and PBRImmersiveScene.body.
- 'stereo != nil' also stands in for three unrelated policies in PBRRenderer: transmissionAsCoverage, writesBlendedDepth, and no screen-space ambient occlusion.

Constraint: no public API changes.

Found by code review; nothing here was built or run.

- `2026-11-17T13:27:19Z`: Related: #30.
- `2026-11-17T13:38:23Z`: Added internal PBRViews (mono or stereo view and projection matrices, view-projections, camera positions, center between the eyes, background inverse view-projections). PBRRenderer, PBREnvironmentBackground, PBRScene and PBRImmersiveScene use it instead of resolving 'stereo ?? mono' themselves. The stereo-dependent policies are named properties with their reasons: transmissionAsCoverage, writesBlendedDepth, and new usesAmbientOcclusion. Public stereo/viewMatrix/projectionMatrix properties unchanged. PBRImmersiveScene (visionOS only) not compiled.

---

## 32: Shared shaders, placeholders and render targets always use the system default device

+++
status: closed
priority: low
kind: bug
labels: architecture, effort:m, area:rendering
created: 2026-11-17T13:26:31Z
updated: 2026-11-17T13:35:19Z
closed: 2026-11-17T13:35:19Z
+++

PBRModelBuilder, PBRGeometryBuilder and PBREnvironment take an MTLDevice. The rest of the renderer does not:

- PBRShaders.make (shader library, samplers, placeholder textures) calls _MTLCreateSystemDefaultDevice() and is cached once per process.
- PBRUpscaleTargets.init calls _MTLCreateSystemDefaultDevice().
- PBRTransmissionTargetCache makes its PBRTransmissionTarget with no device, so the default one.

A model or environment built on another device is drawn with shaders, placeholders and targets from the default device. Nothing checks or reports the mismatch.

Expected: the resources one frame draws with come from one device.

Constraint: no public API changes.

Found by code review; nothing here was built or run.

- `2026-11-17T13:27:19Z`: Related: #33.
- `2026-11-17T13:35:19Z`: Shared shaders and placeholders are made per device (PBRShaders.shared(device:)); PBRRenderer uses the model's device, PBRFrameBindings and PBREnvironmentBackground the environment's, and PBRScene/PBRImmersiveScene make transmission and upscale targets on the first item's model device (the caches key on device). PBRRenderer now stops with a precondition when the model and lighting environment are on different devices. No red-first test: this Mac has one GPU, so a second device cannot be made; RenderTargetTests.sharedResourcesAreMadeOnTheGivenDevice checks resources follow the given device.

---

## 33: Three cache types for one keyed render-target cache

+++
status: closed
priority: low
kind: task
labels: architecture, refactor, effort:xs, area:rendering
created: 2026-11-17T13:26:31Z
updated: 2026-11-17T13:37:28Z
closed: 2026-11-17T13:37:28Z
+++

PBRRenderTargets.swift has PBRKeyedCache plus PBRUpscaleTargetCache and PBRTransmissionTargetCache. The last two each wrap a PBRKeyedCache with a private Key struct and one method that builds the key and calls value(for:make:); their interface is about as large as what they hide. RenderTargetTests tests the wrappers rather than the caching rule.

Constraint: no public API changes.

Found by code review; nothing here was built or run.

- `2026-11-17T13:27:19Z`: Related: #32 (target caches make targets on the default device).
- `2026-11-17T13:37:28Z`: PBRKeyedCache, PBRUpscaleTargetCache and PBRTransmissionTargetCache are replaced by one PBRTargetCache<Target> over a small PBRCachedTarget protocol: each target type declares its Key (size, view count, device...) and init(key:). Call sites pass a key.

---

## 34: Each PBRRenderer copy in a multi-model or pre-pass frame rebuilds the frame bindings

+++
status: closed
priority: low
kind: task
labels: area:rendering, effort:m
created: 2026-11-17T13:33:59Z
updated: 2026-11-17T13:42:18Z
closed: 2026-11-17T13:42:18Z
+++

Split out of #30.

PBRScene, PBRImmersiveScene and PBRTransmissionPass draw one frame with several PBRRenderer values: one per item for the opaque phase, one per blended run, and again for each transmission pre-pass stage. Each one builds its own PBRFrameBindings (lights array, environment, shadow and occlusion bindings) in content(), though those inputs are the same for every renderer in the frame except for the transmission scene and debug flags.

Not measured; found by code review.

- `2026-11-17T13:34:03Z`: Split out of #30.

---

## 35: PBRLighting() builds the studio environment on the calling thread on first use

+++
status: closed
priority: low
kind: enhancement
labels: area:concurrency, effort:s
created: 2026-11-17T13:36:08Z
updated: 2026-11-17T13:42:18Z
closed: 2026-11-17T13:42:18Z
+++

Split out of #27.

PBREnvironment.studio is a static let built on first access, and the build waits for the GPU. It is the default argument of PBRLighting.init, so the first PBRLighting() (often in a view body or element body on the main thread) blocks that thread for the whole studio build (2048x1024 source, 256 specular cube, irradiance, BRDF table).

Avoiding this needs a public API change (for example an async way to get or warm the studio environment), which #27 was not allowed to make.

- `2026-11-17T13:36:08Z`: Question 1 (decision): Add a public async way to warm or get the studio environment? Recommended: Yes
- `2026-11-17T13:40:17Z`: Answer 1: Yes

---

## 36: PBRMaterial cannot be changed safely while another thread renders with it

+++
status: closed
priority: medium
kind: bug
labels: area:api
created: 2026-11-17T19:17:12Z
updated: 2026-11-17T19:23:00Z
closed: 2026-11-17T19:23:00Z
+++

PBRMaterial is a class with public vars (uniforms, renderState, textureTransforms). A render thread reads them every frame while drawing. An app that changes them on another thread (for example material.uniforms.roughnessFactor = x on the main thread) is a data race. There is no supported, race-free way to change one parameter of a live material.

Two derived values also decide which pass a primitive draws in: isBlended and isTransmissive. They are read when the model is built and while drawing.

For merged geometry, the prebuilt material buffer is used unless pose.materialUniforms is not empty or there are overrides (PBRMergedGeometry.materials). An in-place change after the model is built may therefore not show. This has not been verified in a running view.

Found from SceneSprockets#479. In SceneSprockets, SceneView draws on a render thread, and glTF material animation writes material.uniforms every frame.

Expected: PBRMaterial can be changed from one thread while another thread renders with it, without data races, and changes show on the next frame.

---

## 37: Investigate removing merged geometry (PBRMergedGeometry)

+++
status: new
priority: high
kind: task
labels: area:performance, effort:l, investigate
created: 2026-11-17T20:03:34Z
updated: 2026-11-18T18:07:40Z
+++

PBRMergedGeometry merges opaque, unmorphed triangle primitives into shared vertex, index, instance and material buffers so one draw element issues many Metal draws. Its doc comment gives the reason: MetalSprockets' per-frame cost grows with the number of elements, not with Metal draw calls. Merging works around overhead in MetalSprockets; it does not address a GPU cost.

Costs of merging:
- Two drawing paths: merged (opaque static and skinned) and per-batch (blended, morphed, transmissive), each with its own rules.
- Material changes are harder: the merged path reads a prebuilt material buffer, so live material changes need overrides, and pass changes need a model rebuild (SceneSprockets#479, #36).
- Geometry is copied into the shared buffers and rebuilt with the model.

Merging may have been the wrong choice. The per-element overhead it avoids belongs in MetalSprockets, where it is tracked:
- MetalSprockets#476 Argument tables are rebuilt and fully re-bound for every draw on every frame
- MetalSprockets#513 Collapsed parameter chain rebuilds the ParameterSet for every draw every frame
- MetalSprockets#519 Draw subtrees are never reused between frames
- MetalSprockets#522 No closure-free Draw for single draw calls

Merged geometry is not required for GPU-driven rendering: plain indirect draws work per mesh, and indirect command buffers need bindless materials and per-command or addressable vertex data, not one merged buffer (SceneSprockets#517, #520, #522).

There are no measurements. Unknown: the per-element cost in MetalSprockets today, how much merging saves, at what primitive counts, and how that changes if the MetalSprockets issues above are fixed.

Needed before deciding:
- Heavy benchmarks of merged versus per-primitive drawing at several primitive and material counts (CPU frame time, GPU time, memory), in Debug and Release.
- The same benchmarks after the MetalSprockets per-element costs are reduced.

- `2026-11-18T01:22:32Z`: Context for later:
- `2026-11-18T01:22:32Z`: MetalSprockets now runs on a render thread (SceneSprockets#393), so per-element cost no longer blocks the main thread. It still matters if render-thread CPU time per frame exceeds the frame budget (8.3 ms at 120 Hz, 11.1 ms at 90 Hz on visionOS), and for energy. Benchmarks should measure render-thread CPU time against the budget, and energy, not main-thread time.
- `2026-11-18T01:22:32Z`: Existing MetalSprockets data (from its issues, not re-measured): the only profile (GLTFViewer, MetalSprockets#479) showed reconciliation (diffing the element tree each frame) as the hot spot, not argument-table binding (#476, binding never profiled). A static 1000-cube scene spends about 1.75 ms per frame in Update in Release because closure-holding draws never compare equal (#519). In the Cubes benchmark, ParameterModifier.workloadEnter was about 15% of Workload; workload CPU went 7.2 to about 6.8 ms (#513; Debug or Release not stated).
- `2026-11-18T01:22:32Z`: Not measured: tree building (body evaluation) on its own, scaling past 1000 draws, and SceneSprockets' real scenes.
- `2026-11-18T01:22:32Z`: MetalSprockets#519 (reuse unchanged draw subtrees via Equatable payloads, #521-#523) targets the reconciliation cost directly; its outcome bears on whether merging is still needed.
- `2026-11-18T18:13:36Z`: Tracked in SceneSprockets as #545.

---

## 38: Scene-wide lighting inputs are bound one slot at a time on every draw

+++
status: new
priority: medium
kind: enhancement
labels: area:performance,effort:m
created: 2026-11-18T18:18:13Z
+++

Material textures are already bindless: each PBRMaterial writes its textures and samplers into a PBRMaterialResources argument buffer once, and draws find them by index.

The scene-wide lighting inputs are not. The environment irradiance and specular cubes, the BRDF lookup, the transmission scene texture, the shadow map, the ambient occlusion texture and their samplers are bound as separate texture and sampler slots (PBR.metal: brdfLookup [[texture(2)]], ambientOcclusion [[texture(5)]], environmentSampler [[sampler(0)]], shadowSampler [[sampler(1)]], ...) on every draw, every frame, although they are the same for every draw in a frame.

Effects:
- Per-draw binding cost that grows with the number of draws.
- Shaders outside this package that call PBR::shade (SceneSprocketsAddOns voxel and signed-distance renderers) must repeat the same slot layout by hand.
- Indirect command buffer commands cannot bind these textures.

Depends on: MetalSprockets#579 (no persistent argument buffers).
Related: SceneSprockets#542 (no shared lighting model).

---
