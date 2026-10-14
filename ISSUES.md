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
status: new
priority: low
kind: enhancement
created: 2026-10-14T19:07:32Z
+++

PBR has no pixel tests, and the README has no image.

Add golden image tests with the GoldenImage package (github.com/schwa/GoldenImage), like MetalSprocketsGLTF's GoldenImageTests:
- Render scenes built in code (for example the README example, plus a grid of spheres with different metallic and roughness values) through OffscreenRenderer.
- Store the goldens in Tests/MetalSprocketsPBRTests/GoldenImages.
- Gate the suite with .requiresMetal4 so GitHub CI skips it; Buildkite runs it on real hardware.
- Use one golden (a larger render) as the README screenshot.

---
