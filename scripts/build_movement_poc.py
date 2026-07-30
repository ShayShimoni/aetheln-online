"""Reproducible Unreal Editor authoring helper for movement POC issue #100.

Run inside the temporary Third Person source project with ``audit-source`` to
resolve the exact asset dependency closure. Run inside Aetheln Online with
``author-target`` after the native modules and audited assets are present.
"""

from __future__ import annotations

import json
import pathlib
import unreal


CHARACTER_ROOTS = (
    "/Game/Characters/Mannequins/Meshes/SKM_Quinn_Simple",
    "/Game/Characters/Mannequins/Anims/Unarmed/ABP_Unarmed",
)
GREYBOX_ROOTS = (
    "/Game/LevelPrototyping/Meshes/SM_Cube",
    "/Game/LevelPrototyping/Meshes/SM_Ramp",
)
ALLOWED_GAME_PREFIXES = (
    "/Game/Characters/Mannequins/",
    "/Game/LevelPrototyping/",
)
SOURCE_ANIMATION_BLUEPRINT_PATH = (
    "/Game/Characters/Mannequins/Anims/Unarmed/ABP_Unarmed"
)
POC_ANIMATION_BLUEPRINT_PATH = "/Game/POC/ABP_MovementPOCLocomotion"
SOURCE_BLEND_SPACE_PATH = (
    "/Game/Characters/Mannequins/Anims/Unarmed/BS_Idle_Walk_Run"
)
POC_BLEND_SPACE_PATH = "/Game/POC/BS_MovementPOCLocomotion"
POC_LATERAL_SAMPLE_REMAPS = {
    (-90, 300): (
        "/Game/Characters/Mannequins/Anims/Unarmed/Walk/"
        "MF_Unarmed_Walk_Fwd_Left"
    ),
    (90, 300): (
        "/Game/Characters/Mannequins/Anims/Unarmed/Walk/"
        "MF_Unarmed_Walk_Fwd_Right"
    ),
    (-90, 600): (
        "/Game/Characters/Mannequins/Anims/Unarmed/Jog/"
        "MF_Unarmed_Jog_Fwd_Left"
    ),
    (90, 600): (
        "/Game/Characters/Mannequins/Anims/Unarmed/Jog/"
        "MF_Unarmed_Jog_Fwd_Right"
    ),
}


def _project_root() -> pathlib.Path:
    return pathlib.Path(unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_dir()))


def _dependency_options(include_soft: bool) -> unreal.AssetRegistryDependencyOptions:
    options = unreal.AssetRegistryDependencyOptions()
    options.include_hard_package_references = True
    options.include_soft_package_references = include_soft
    options.include_hard_management_references = False
    options.include_soft_management_references = False
    options.include_searchable_names = False
    return options


def _game_dependency_closure(
    roots: tuple[str, ...], *, include_soft: bool
) -> list[str]:
    registry = unreal.AssetRegistryHelpers.get_asset_registry()
    registry.scan_paths_synchronous(list(ALLOWED_GAME_PREFIXES), True)
    options = _dependency_options(include_soft)
    pending = list(roots)
    visited: set[str] = set()

    while pending:
        package = pending.pop()
        if package in visited:
            continue
        visited.add(package)
        for dependency in registry.get_dependencies(package, options):
            dependency_name = str(dependency)
            if dependency_name.startswith("/Game/") and dependency_name not in visited:
                pending.append(dependency_name)

    unexpected = sorted(
        package
        for package in visited
        if package.startswith("/Game/")
        and not package.startswith(ALLOWED_GAME_PREFIXES)
    )
    if unexpected:
        raise RuntimeError(f"Dependency closure escaped approved families: {unexpected}")

    return sorted(package for package in visited if package.startswith("/Game/"))


def _package_source_file(package: str) -> pathlib.Path:
    relative = package.removeprefix("/Game/")
    content_dir = pathlib.Path(
        unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir())
    )
    for extension in (".uasset", ".umap"):
        candidate = content_dir / f"{relative}{extension}"
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"No package file found for {package}")


def audit_source(output_path: pathlib.Path) -> None:
    roots = CHARACTER_ROOTS + GREYBOX_ROOTS
    closure = _game_dependency_closure(roots, include_soft=False)
    closure_with_soft = _game_dependency_closure(roots, include_soft=True)
    assets = [
        {
            "package": package,
            "relative_file": _package_source_file(package)
            .relative_to(_project_root() / "Content")
            .as_posix(),
            "bytes": _package_source_file(package).stat().st_size,
        }
        for package in closure
    ]
    report = {
        "schema": "aetheln_movement_poc_asset_closure_v1",
        "roots": list(roots),
        "assets": assets,
        "total_bytes": sum(asset["bytes"] for asset in assets),
        "soft_only_packages": sorted(set(closure_with_soft) - set(closure)),
        "asset_tools_methods": sorted(
            name
            for name in dir(unreal.AssetToolsHelpers.get_asset_tools())
            if "migrat" in name.lower()
        ),
        "migrate_packages_doc": str(
            getattr(unreal.AssetTools, "migrate_packages").__doc__
        ),
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    unreal.log(f"Movement POC dependency audit wrote {output_path}")


def migrate_source(destination_content: pathlib.Path) -> None:
    closure = _game_dependency_closure(
        CHARACTER_ROOTS + GREYBOX_ROOTS, include_soft=False
    )
    options = unreal.MigrationOptions()
    options.prompt = False
    options.ignore_dependencies = True
    options.asset_conflict = unreal.AssetMigrationConflict.SKIP
    unreal.AssetToolsHelpers.get_asset_tools().migrate_packages(
        [unreal.Name(package) for package in closure],
        destination_content.as_posix(),
        options,
    )
    unreal.log(
        f"Movement POC migrated {len(closure)} audited packages to "
        f"{destination_content}"
    )


def _create_blueprint(
    asset_name: str, package_path: str, parent_class: unreal.Class
) -> unreal.Blueprint:
    asset_path = f"{package_path}/{asset_name}"
    if unreal.EditorAssetLibrary.does_asset_exist(asset_path):
        existing = unreal.EditorAssetLibrary.load_asset(asset_path)
        if not isinstance(existing, unreal.Blueprint):
            raise RuntimeError(f"Existing asset is not a Blueprint: {asset_path}")
        return existing

    factory = unreal.BlueprintFactory()
    factory.set_editor_property("parent_class", parent_class)
    blueprint = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
        asset_name,
        package_path,
        unreal.Blueprint,
        factory,
    )
    if blueprint is None:
        raise RuntimeError(f"Failed to create Blueprint: {asset_path}")
    unreal.BlueprintEditorLibrary.compile_blueprint(blueprint)
    return blueprint


def _blueprint_class(asset_path: str) -> unreal.Class:
    blueprint_class = unreal.EditorAssetLibrary.load_blueprint_class(asset_path)
    if blueprint_class is None:
        raise RuntimeError(f"Failed to load generated class for {asset_path}")
    return blueprint_class


def _ensure_poc_blend_space() -> unreal.BlendSpace:
    if not unreal.EditorAssetLibrary.does_asset_exist(
        POC_BLEND_SPACE_PATH
    ):
        duplicate = unreal.EditorAssetLibrary.duplicate_asset(
            SOURCE_BLEND_SPACE_PATH,
            POC_BLEND_SPACE_PATH,
        )
        if not isinstance(duplicate, unreal.BlendSpace):
            raise RuntimeError(
                "Failed to create the Movement POC locomotion BlendSpace"
            )

    blend_space = unreal.EditorAssetLibrary.load_asset(
        POC_BLEND_SPACE_PATH
    )
    if not isinstance(blend_space, unreal.BlendSpace):
        raise RuntimeError(
            "Movement POC locomotion BlendSpace failed to load"
        )

    blend_space.set_editor_property(
        "target_weight_interpolation_speed_per_sec",
        12.0,
    )
    blend_space.set_editor_property(
        "target_weight_interpolation_ease_in_out",
        False,
    )

    sample_data = blend_space.get_editor_property("sample_data")
    updated_sample_data = []
    remapped_samples = set()
    for sample in sample_data:
        sample_value = sample.get_editor_property("sample_value")
        sample_key = (
            round(sample_value.x),
            round(sample_value.y),
        )
        replacement_path = POC_LATERAL_SAMPLE_REMAPS.get(
            sample_key
        )
        animation = sample.get_editor_property("animation")
        if replacement_path is not None:
            animation = unreal.load_asset(replacement_path)
            if not isinstance(animation, unreal.AnimSequence):
                raise RuntimeError(
                    "Movement POC lateral replacement failed to load: "
                    f"{replacement_path}"
                )
            remapped_samples.add(sample_key)

        updated_sample = unreal.BlendSample()
        updated_sample.set_editor_property("animation", animation)
        updated_sample.set_editor_property(
            "sample_value",
            sample_value,
        )
        updated_sample.set_editor_property(
            "rate_scale",
            sample.get_editor_property("rate_scale"),
        )
        updated_sample.set_editor_property(
            "include_in_analyse_all",
            sample.get_editor_property("include_in_analyse_all"),
        )
        updated_sample.set_editor_property(
            "frame_index_to_sample",
            sample.get_editor_property("frame_index_to_sample"),
        )
        updated_sample_data.append(updated_sample)
    if remapped_samples != set(POC_LATERAL_SAMPLE_REMAPS):
        raise RuntimeError(
            "Movement POC lateral sample remap was incomplete: "
            f"{sorted(remapped_samples)}"
        )
    blend_space.set_editor_property(
        "sample_data",
        updated_sample_data,
    )

    if not unreal.EditorAssetLibrary.save_loaded_asset(
        blend_space, False
    ):
        raise RuntimeError(
            "Failed to save the Movement POC locomotion BlendSpace"
        )
    return blend_space


def _ensure_poc_animation_blueprint() -> unreal.Class:
    if not unreal.EditorAssetLibrary.does_asset_exist(
        POC_ANIMATION_BLUEPRINT_PATH
    ):
        duplicate = unreal.EditorAssetLibrary.duplicate_asset(
            SOURCE_ANIMATION_BLUEPRINT_PATH,
            POC_ANIMATION_BLUEPRINT_PATH,
        )
        if not isinstance(duplicate, unreal.AnimBlueprint):
            raise RuntimeError(
                "Failed to create the Movement POC animation Blueprint"
            )

    animation_blueprint = unreal.EditorAssetLibrary.load_asset(
        POC_ANIMATION_BLUEPRINT_PATH
    )
    if not isinstance(animation_blueprint, unreal.AnimBlueprint):
        raise RuntimeError(
            "Movement POC animation Blueprint failed to load"
        )

    blend_space = _ensure_poc_blend_space()
    matching_blend_nodes = []
    for node in unreal.ObjectIterator(
        unreal.AnimGraphNode_BlendSpacePlayer
    ):
        if not node.get_path_name().startswith(
            f"{POC_ANIMATION_BLUEPRINT_PATH}."
        ):
            continue
        runtime_node = node.get_editor_property("node")
        if runtime_node.get_editor_property("blend_space") is None:
            continue
        matching_blend_nodes.append(node)

    if len(matching_blend_nodes) != 1:
        raise RuntimeError(
            "Expected one locomotion BlendSpace player in the Movement POC "
            f"animation Blueprint, found {len(matching_blend_nodes)}"
        )

    blend_node = matching_blend_nodes[0]
    runtime_node = blend_node.get_editor_property("node")
    runtime_node.set_editor_property("blend_space", blend_space)
    blend_node.set_editor_property("node", runtime_node)

    matching_select_nodes = []
    for node in unreal.ObjectIterator(unreal.K2Node):
        if not node.get_path_name().startswith(
            f"{POC_ANIMATION_BLUEPRINT_PATH}."
        ):
            continue
        if not isinstance(node, unreal.K2Node_Select):
            continue
        if ":EventGraph." not in node.get_path_name():
            continue

        option_one_pin = unreal.BlueprintEditorLibrary.find_input_pin(
            node, "Option 1"
        )
        return_pin = unreal.BlueprintEditorLibrary.find_output_pin(
            node, "ReturnValue"
        )
        option_one_links = (
            unreal.BlueprintGraphPinLibrary.list_connected_pins(
                option_one_pin
            )
        )
        return_links = (
            unreal.BlueprintGraphPinLibrary.list_connected_pins(return_pin)
        )
        if not any(
            unreal.BlueprintEditorLibrary.get_node_title(
                unreal.BlueprintGraphPinLibrary.get_owning_node(pin)
            )
            == "Clamp (Float)"
            for pin in option_one_links
        ):
            continue
        if not any(
            unreal.BlueprintEditorLibrary.get_node_title(
                unreal.BlueprintGraphPinLibrary.get_owning_node(pin)
            )
            == "Set Direction"
            for pin in return_links
        ):
            continue
        matching_select_nodes.append(node)

    if len(matching_select_nodes) != 1:
        raise RuntimeError(
            "Expected one locomotion Direction selector in the Movement POC "
            f"animation Blueprint, found {len(matching_select_nodes)}"
        )

    select_node = matching_select_nodes[0]
    index_pin = unreal.BlueprintEditorLibrary.find_input_pin(
        select_node, "Index"
    )
    for connected_pin in list(
        unreal.BlueprintGraphPinLibrary.list_connected_pins(index_pin)
    ):
        if not unreal.BlueprintGraphPinLibrary.break_single_pin_link(
            index_pin,
            connected_pin,
        ):
            raise RuntimeError(
                "Failed to disconnect the template rotation-mode selector"
            )

    matching_orientation_nodes = []
    for node in unreal.ObjectIterator(unreal.K2Node):
        if not node.get_path_name().startswith(
            f"{POC_ANIMATION_BLUEPRINT_PATH}."
        ):
            continue
        if ":EventGraph." not in node.get_path_name():
            continue
        if (
            unreal.BlueprintEditorLibrary.get_node_title(node)
            == "Get bOrientRotationToMovement"
        ):
            matching_orientation_nodes.append(node)
    if len(matching_orientation_nodes) != 1:
        raise RuntimeError(
            "Expected one movement-orientation getter in the Movement POC "
            f"animation Blueprint, found {len(matching_orientation_nodes)}"
        )
    orientation_pin = unreal.BlueprintEditorLibrary.find_output_pin(
        matching_orientation_nodes[0],
        "bOrientRotationToMovement",
    )
    if not unreal.BlueprintGraphPinLibrary.try_create_connection(
        orientation_pin,
        index_pin,
    ):
        raise RuntimeError(
            "Failed to restore the locomotion direction-mode selector"
        )

    unreal.BlueprintEditorLibrary.compile_blueprint(animation_blueprint)
    if not unreal.EditorAssetLibrary.save_loaded_asset(
        animation_blueprint, False
    ):
        raise RuntimeError(
            "Failed to save the Movement POC animation Blueprint"
        )
    return _blueprint_class(POC_ANIMATION_BLUEPRINT_PATH)


def _spawn_static_geometry(
    mesh: unreal.StaticMesh,
    material: unreal.MaterialInterface,
    label: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> unreal.StaticMeshActor:
    pitch, yaw, roll = rotation
    actor = unreal.EditorLevelLibrary.spawn_actor_from_class(
        unreal.StaticMeshActor,
        unreal.Vector(*location),
        unreal.Rotator(roll=roll, pitch=pitch, yaw=yaw),
    )
    if actor is None:
        raise RuntimeError(f"Failed to spawn geometry actor {label}")

    actor.set_actor_label(label)
    actor.set_folder_path("POC/Geometry")
    actor.set_actor_scale3d(unreal.Vector(*scale))
    actor.set_actor_tick_enabled(False)

    component = actor.static_mesh_component
    component.set_static_mesh(mesh)
    component.set_material(0, material)
    component.set_editor_property("mobility", unreal.ComponentMobility.STATIC)
    component.set_collision_enabled(unreal.CollisionEnabled.QUERY_AND_PHYSICS)
    component.set_collision_profile_name("BlockAll")
    return actor


def repair_target_collision(output_path: pathlib.Path) -> None:
    cube = unreal.load_asset("/Game/LevelPrototyping/Meshes/SM_Cube")
    ramp = unreal.load_asset("/Game/LevelPrototyping/Meshes/SM_Ramp")
    if cube is None or ramp is None:
        raise RuntimeError("Level Prototyping collision meshes failed to load")

    before = {
        "SM_Cube": unreal.EditorStaticMeshLibrary.get_simple_collision_count(
            cube
        ),
        "SM_Ramp": unreal.EditorStaticMeshLibrary.get_simple_collision_count(
            ramp
        ),
        "SM_RampComplexity": str(
            unreal.EditorStaticMeshLibrary.get_collision_complexity(ramp)
        ),
    }

    if before["SM_Cube"] <= 0:
        collision_index = unreal.EditorStaticMeshLibrary.add_simple_collisions(
            cube,
            unreal.ScriptCollisionShapeType.BOX,
        )
        if collision_index < 0:
            raise RuntimeError("Failed to add box collision to SM_Cube")

    if before["SM_Ramp"] <= 0:
        unreal.EditorStaticMeshLibrary.set_convex_decomposition_collisions(
            ramp,
            1,
            16,
            100000,
        )
        if (
            unreal.EditorStaticMeshLibrary.get_simple_collision_count(ramp)
            <= 0
        ):
            collision_index = (
                unreal.EditorStaticMeshLibrary.add_simple_collisions(
                    ramp,
                    unreal.ScriptCollisionShapeType.NDOP26,
                )
            )
            if collision_index < 0:
                raise RuntimeError(
                    "Failed to add simplified collision to SM_Ramp"
                )
        if (
            unreal.EditorStaticMeshLibrary.get_simple_collision_count(ramp)
            <= 0
        ):
            body_setup = ramp.get_editor_property("body_setup")
            body_setup.set_editor_property(
                "collision_trace_flag",
                unreal.CollisionTraceFlag.CTF_USE_COMPLEX_AS_SIMPLE,
            )

    unreal.EditorAssetLibrary.save_loaded_asset(cube, False)
    unreal.EditorAssetLibrary.save_loaded_asset(ramp, False)

    after = {
        "SM_Cube": unreal.EditorStaticMeshLibrary.get_simple_collision_count(
            cube
        ),
        "SM_Ramp": unreal.EditorStaticMeshLibrary.get_simple_collision_count(
            ramp
        ),
        "SM_RampComplexity": str(
            unreal.EditorStaticMeshLibrary.get_collision_complexity(ramp)
        ),
    }
    if after["SM_Cube"] <= 0 or (
        after["SM_Ramp"] <= 0
        and "USE_COMPLEX_AS_SIMPLE" not in after["SM_RampComplexity"]
    ):
        raise RuntimeError(f"Collision repair did not persist: {after}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            {
                "schema": "aetheln_movement_poc_collision_repair_v1",
                "before": before,
                "after": after,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    unreal.log(f"Movement POC collision repair wrote {output_path}")


def repair_target_geometry(output_path: pathlib.Path) -> None:
    if not unreal.EditorLevelLibrary.load_level("/Game/Maps/MovementPOC"):
        raise RuntimeError("Failed to load MovementPOC for geometry repair")

    engine_cube = unreal.load_asset("/Engine/BasicShapes/Cube")
    if engine_cube is None:
        raise RuntimeError("Engine-native cube collision mesh failed to load")

    replaced = []
    for actor in unreal.EditorLevelLibrary.get_all_level_actors():
        if not isinstance(actor, unreal.StaticMeshActor):
            continue
        component = actor.static_mesh_component
        static_mesh = component.get_editor_property("static_mesh")
        if (
            static_mesh is None
            or static_mesh.get_path_name()
            != "/Game/LevelPrototyping/Meshes/SM_Cube.SM_Cube"
        ):
            continue

        component.set_static_mesh(engine_cube)
        component.set_collision_enabled(
            unreal.CollisionEnabled.QUERY_AND_PHYSICS
        )
        component.set_collision_profile_name("BlockAll")
        replaced.append(actor.get_actor_label())

    if len(replaced) != 15:
        raise RuntimeError(
            f"Expected to replace 15 cube actors, replaced {len(replaced)}"
        )
    if not unreal.EditorLevelLibrary.save_current_level():
        raise RuntimeError("Failed to save MovementPOC geometry repair")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            {
                "schema": "aetheln_movement_poc_geometry_repair_v1",
                "replacement_mesh": engine_cube.get_path_name(),
                "replaced_actor_count": len(replaced),
                "replaced_actors": sorted(replaced),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    unreal.log(f"Movement POC geometry repair wrote {output_path}")


def _rotator_report(rotation: unreal.Rotator) -> dict[str, float]:
    return {
        "pitch": rotation.pitch,
        "yaw": rotation.yaw,
        "roll": rotation.roll,
    }


def repair_target_presentation(output_path: pathlib.Path) -> None:
    character_asset_path = "/Game/POC/BP_MovementPOCCharacter"
    character_blueprint = unreal.EditorAssetLibrary.load_asset(
        character_asset_path
    )
    if not isinstance(character_blueprint, unreal.Blueprint):
        raise RuntimeError(
            f"Movement POC character Blueprint failed to load: "
            f"{character_asset_path}"
        )

    character_class = _blueprint_class(character_asset_path)
    character_cdo = unreal.get_default_object(character_class)
    mesh_component = character_cdo.get_editor_property("mesh")
    before = mesh_component.get_editor_property("relative_rotation")
    expected = unreal.Rotator(roll=0.0, pitch=0.0, yaw=-90.0)
    mesh_component.set_relative_rotation(expected, False, False)

    if not unreal.EditorAssetLibrary.save_loaded_asset(
        character_blueprint, False
    ):
        raise RuntimeError("Failed to save Movement POC character alignment")

    after = mesh_component.get_editor_property("relative_rotation")
    if (
        abs(after.pitch) > 0.01
        or abs(after.roll) > 0.01
        or abs(after.yaw + 90.0) > 0.01
    ):
        raise RuntimeError(
            f"Movement POC character alignment did not persist: {after}"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            {
                "schema": "aetheln_movement_poc_presentation_repair_v1",
                "character_blueprint": character_asset_path,
                "before": _rotator_report(before),
                "after": _rotator_report(after),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    unreal.log(f"Movement POC presentation repair wrote {output_path}")


def repair_target_lateral_animation(output_path: pathlib.Path) -> None:
    animation_class = _ensure_poc_animation_blueprint()
    character_asset_path = "/Game/POC/BP_MovementPOCCharacter"
    character_blueprint = unreal.EditorAssetLibrary.load_asset(
        character_asset_path
    )
    if not isinstance(character_blueprint, unreal.Blueprint):
        raise RuntimeError(
            f"Movement POC character Blueprint failed to load: "
            f"{character_asset_path}"
        )

    character_class = _blueprint_class(character_asset_path)
    character_cdo = unreal.get_default_object(character_class)
    mesh_component = character_cdo.get_editor_property("mesh")
    mesh_component.set_anim_instance_class(animation_class)
    if not unreal.EditorAssetLibrary.save_loaded_asset(
        character_blueprint, False
    ):
        raise RuntimeError(
            "Failed to assign the Movement POC animation Blueprint"
        )

    assigned_class = mesh_component.get_editor_property("anim_class")
    if assigned_class != animation_class:
        raise RuntimeError(
            "Movement POC animation Blueprint assignment did not persist"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            {
                "schema": (
                    "aetheln_movement_poc_lateral_animation_repair_v1"
                ),
                "source_animation_blueprint": (
                    SOURCE_ANIMATION_BLUEPRINT_PATH
                ),
                "poc_animation_blueprint": POC_ANIMATION_BLUEPRINT_PATH,
                "source_blend_space": SOURCE_BLEND_SPACE_PATH,
                "poc_blend_space": POC_BLEND_SPACE_PATH,
                "blend_space_weight_speed": 12.0,
                "blend_space_ease_in_out": False,
                "direction_selector": "bOrientRotationToMovement",
                "lateral_sample_remaps": {
                    f"{direction},{speed}": path
                    for (
                        direction,
                        speed,
                    ), path in POC_LATERAL_SAMPLE_REMAPS.items()
                },
                "assigned_animation_class": (
                    assigned_class.get_path_name()
                ),
                "direction_clamp_degrees": [-45.0, 45.0],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    unreal.log(
        f"Movement POC lateral animation repair wrote {output_path}"
    )


def audit_target_animation(output_path: pathlib.Path) -> None:
    blend_space_path = SOURCE_BLEND_SPACE_PATH
    blend_space = unreal.load_asset(blend_space_path)
    if not isinstance(blend_space, unreal.BlendSpace):
        raise RuntimeError(
            f"Movement POC blend space failed to load: {blend_space_path}"
        )

    axes = []
    for parameter in blend_space.get_editor_property("blend_parameters"):
        axes.append(
            {
                "display_name": str(
                    parameter.get_editor_property("display_name")
                ),
                "min": parameter.get_editor_property("min"),
                "max": parameter.get_editor_property("max"),
                "grid_num": parameter.get_editor_property("grid_num"),
                "wrap_input": parameter.get_editor_property("wrap_input"),
            }
        )

    input_interpolation = []
    for parameter in blend_space.get_editor_property("interpolation_param"):
        input_interpolation.append(
            {
                "interpolation_time": parameter.get_editor_property(
                    "interpolation_time"
                ),
                "interpolation_type": str(
                    parameter.get_editor_property("interpolation_type")
                ),
                "damping_ratio": parameter.get_editor_property(
                    "damping_ratio"
                ),
                "max_speed": parameter.get_editor_property("max_speed"),
            }
        )

    samples = []
    for sample in blend_space.get_editor_property("sample_data"):
        animation = sample.get_editor_property("animation")
        sample_value = sample.get_editor_property("sample_value")
        samples.append(
            {
                "animation": (
                    animation.get_path_name() if animation is not None else None
                ),
                "x": sample_value.x,
                "y": sample_value.y,
                "z": sample_value.z,
            }
        )

    lateral_pose_samples = []
    for animation_path in (
        "/Game/Characters/Mannequins/Anims/Unarmed/Jog/"
        "MF_Unarmed_Jog_Left",
        "/Game/Characters/Mannequins/Anims/Unarmed/Jog/"
        "MF_Unarmed_Jog_Right",
    ):
        animation = unreal.load_asset(animation_path)
        if not isinstance(animation, unreal.AnimSequence):
            raise RuntimeError(
                f"Movement POC lateral animation failed to load: "
                f"{animation_path}"
            )
        frame = max(animation.get_editor_property("number_of_sampled_frames") // 2, 0)
        lateral_pose_samples.append(
            {
                "animation": animation_path,
                "frame": frame,
                "pelvis": str(
                    unreal.AnimationLibrary.get_bone_pose_for_frame(
                        animation,
                        "pelvis",
                        frame,
                        False,
                    )
                ),
                "head": str(
                    unreal.AnimationLibrary.get_bone_pose_for_frame(
                        animation,
                        "head",
                        frame,
                        False,
                    )
                ),
            }
        )

    animation_blueprint_path = SOURCE_ANIMATION_BLUEPRINT_PATH
    animation_blueprint = unreal.load_asset(animation_blueprint_path)
    if not isinstance(animation_blueprint, unreal.AnimBlueprint):
        raise RuntimeError(
            f"Movement POC animation Blueprint failed to load: "
            f"{animation_blueprint_path}"
        )
    unreal.SystemLibrary.execute_console_command(
        animation_blueprint,
        "DISASMSCRIPT ABP_Unarmed_C",
    )
    animation_graph_nodes = []
    for node in unreal.ObjectIterator(unreal.K2Node):
        node_path = node.get_path_name()
        if "ABP_Unarmed" not in node_path:
            continue
        node_title = unreal.BlueprintEditorLibrary.get_node_title(node)
        node_class = node.get_class().get_name()
        if not any(
            token in f"{node_title} {node_class}"
            for token in (
                "Direction",
                "BlendSpace",
                "Idle Walk Run",
                "Select",
                "Clamp",
                "Velocity",
                "Movement",
                "Rotation",
            )
        ):
            continue

        pins = []
        for pin in unreal.BlueprintEditorLibrary.list_all_pins(node):
            connected = []
            for connected_pin in (
                unreal.BlueprintGraphPinLibrary.list_connected_pins(pin)
            ):
                connected_node = (
                    unreal.BlueprintGraphPinLibrary.get_owning_node(
                        connected_pin
                    )
                )
                connected.append(
                    {
                        "node": (
                            unreal.BlueprintEditorLibrary.get_node_title(
                                connected_node
                            )
                        ),
                        "pin": str(
                            unreal.BlueprintGraphPinLibrary.get_pin_name(
                                connected_pin
                            )
                        ),
                    }
                )
            pins.append(
                {
                    "name": str(
                        unreal.BlueprintGraphPinLibrary.get_pin_name(pin)
                    ),
                    "direction": str(
                        unreal.BlueprintGraphPinLibrary.get_pin_direction(pin)
                    ),
                    "value": (
                        unreal.BlueprintGraphPinLibrary.get_pin_value(pin)
                    ),
                    "connected": connected,
                }
            )
        animation_graph_nodes.append(
            {
                "class": node_class,
                "path": node_path,
                "title": node_title,
                "pins": pins,
            }
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            {
                "schema": "aetheln_movement_poc_animation_audit_v1",
                "blend_space": blend_space_path,
                "target_weight_interpolation_speed_per_sec": (
                    blend_space.get_editor_property(
                        "target_weight_interpolation_speed_per_sec"
                    )
                ),
                "target_weight_interpolation_ease_in_out": (
                    blend_space.get_editor_property(
                        "target_weight_interpolation_ease_in_out"
                    )
                ),
                "axes": axes,
                "input_interpolation": input_interpolation,
                "samples": samples,
                "lateral_pose_samples": lateral_pose_samples,
                "animation_blueprint": animation_blueprint_path,
                "animation_graph_nodes": animation_graph_nodes,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    unreal.log(f"Movement POC animation audit wrote {output_path}")


def author_target(output_path: pathlib.Path) -> None:
    character_asset_path = "/Game/POC/BP_MovementPOCCharacter"
    game_mode_asset_path = "/Game/POC/BP_MovementPOCGameMode"
    map_asset_path = "/Game/Maps/MovementPOC"

    character_parent = unreal.load_class(
        None, "/Script/GameCore.AethelnPlayerCharacter"
    )
    input_component_class = unreal.load_class(
        None, "/Script/GameUI.AethelnPOCInputComponent"
    )
    game_mode_parent = unreal.load_class(None, "/Script/GameCore.AethelnGameModeBase")
    if not all((character_parent, input_component_class, game_mode_parent)):
        raise RuntimeError("POC native classes are not loaded in the Editor target")

    character_blueprint = _create_blueprint(
        "BP_MovementPOCCharacter", "/Game/POC", character_parent
    )
    character_class = _blueprint_class(character_asset_path)
    character_cdo = unreal.get_default_object(character_class)
    character_cdo.set_editor_property(
        "override_input_component_class", input_component_class
    )

    skeletal_mesh = unreal.load_asset(
        "/Game/Characters/Mannequins/Meshes/SKM_Quinn_Simple"
    )
    anim_class = _ensure_poc_animation_blueprint()
    if skeletal_mesh is None or anim_class is None:
        raise RuntimeError("Quinn presentation assets failed to load")

    mesh_component = character_cdo.get_editor_property("mesh")
    mesh_component.set_skeletal_mesh_asset(skeletal_mesh)
    mesh_component.set_anim_instance_class(anim_class)
    mesh_component.set_relative_location(
        unreal.Vector(0.0, 0.0, -96.0), False, False
    )
    mesh_component.set_relative_rotation(
        unreal.Rotator(roll=0.0, pitch=0.0, yaw=-90.0), False, False
    )
    mesh_component.set_collision_enabled(unreal.CollisionEnabled.NO_COLLISION)
    unreal.EditorAssetLibrary.save_loaded_asset(character_blueprint, False)

    game_mode_blueprint = _create_blueprint(
        "BP_MovementPOCGameMode", "/Game/POC", game_mode_parent
    )
    game_mode_class = _blueprint_class(game_mode_asset_path)
    game_mode_cdo = unreal.get_default_object(game_mode_class)
    game_mode_cdo.set_editor_property("default_pawn_class", character_class)
    unreal.EditorAssetLibrary.save_loaded_asset(game_mode_blueprint, False)

    if unreal.EditorAssetLibrary.does_asset_exist(map_asset_path):
        if not unreal.EditorLevelLibrary.load_level(map_asset_path):
            raise RuntimeError(f"Failed to load partial map {map_asset_path}")
        if unreal.EditorLevelLibrary.get_all_level_actors():
            raise RuntimeError(
                f"Refusing to duplicate actors in existing map {map_asset_path}"
            )
    elif not unreal.EditorLevelLibrary.new_level(map_asset_path):
        raise RuntimeError(f"Failed to create map {map_asset_path}")

    world = unreal.EditorLevelLibrary.get_editor_world()
    if world is None:
        raise RuntimeError("Editor world is unavailable after map creation")
    world_settings = world.get_world_settings()
    world_settings.set_editor_property("default_game_mode", game_mode_class)

    cube = unreal.load_asset("/Engine/BasicShapes/Cube")
    ramp = unreal.load_asset("/Game/LevelPrototyping/Meshes/SM_Ramp")
    grey_material = unreal.load_asset(
        "/Game/LevelPrototyping/Materials/MI_PrototypeGrid_Gray"
    )
    if cube is None or ramp is None or grey_material is None:
        raise RuntimeError("Level Prototyping assets failed to load")

    geometry = [
        ("SafetyFloor_60m", cube, (0, 0, -50), (60, 60, 1), (0, 0, 0)),
        ("Boundary_North", cube, (0, 2950, 150), (60, 1, 4), (0, 0, 0)),
        ("Boundary_South", cube, (0, -2950, 150), (60, 1, 4), (0, 0, 0)),
        ("Boundary_East", cube, (2950, 0, 150), (1, 58, 4), (0, 0, 0)),
        ("Boundary_West", cube, (-2950, 0, 150), (1, 58, 4), (0, 0, 0)),
        ("Ramp_Up", ramp, (-1450, -500, 0), (6, 4, 2), (0, 0, 0)),
        ("Raised_Platform", cube, (-600, -500, 100), (10, 5, 2), (0, 0, 0)),
        ("Ramp_Down", ramp, (250, -500, 0), (6, 4, 2), (0, 180, 0)),
        ("Step_01", cube, (900, -1450, 12.5), (4, 1, 0.25), (0, 0, 0)),
        ("Step_02", cube, (900, -1350, 25), (4, 1, 0.5), (0, 0, 0)),
        ("Step_03", cube, (900, -1250, 37.5), (4, 1, 0.75), (0, 0, 0)),
        ("Step_04", cube, (900, -1150, 50), (4, 1, 1), (0, 0, 0)),
        ("Corridor_Left", cube, (1150, 650, 125), (16, 1, 2.5), (0, 0, 0)),
        ("Corridor_Right", cube, (1150, 950, 125), (16, 1, 2.5), (0, 0, 0)),
        ("Camera_Check_01", cube, (-1750, 1150, 150), (3, 3, 3), (0, 0, 0)),
        ("Camera_Check_02", cube, (-900, 1600, 225), (2, 2, 4.5), (0, 0, 0)),
        ("Camera_Check_03", cube, (-100, 1250, 100), (4, 2, 2), (0, 25, 0)),
    ]
    for label, mesh, location, scale, rotation in geometry:
        _spawn_static_geometry(
            mesh, grey_material, label, location, scale, rotation
        )

    player_start = unreal.EditorLevelLibrary.spawn_actor_from_class(
        unreal.PlayerStart,
        unreal.Vector(-2200.0, -2100.0, 110.0),
        unreal.Rotator(roll=0.0, pitch=0.0, yaw=35.0),
    )
    player_start.set_actor_label("MovementPOC_PlayerStart")
    player_start.set_folder_path("POC/Setup")
    player_start.set_actor_tick_enabled(False)

    sun = unreal.EditorLevelLibrary.spawn_actor_from_class(
        unreal.DirectionalLight,
        unreal.Vector(0.0, 0.0, 1000.0),
        unreal.Rotator(roll=0.0, pitch=-45.0, yaw=-35.0),
    )
    sun.set_actor_label("MovementPOC_Sun")
    sun.set_folder_path("POC/Lighting")
    sun.set_actor_tick_enabled(False)
    sun_component = sun.get_component_by_class(unreal.DirectionalLightComponent)
    sun_component.set_editor_property("mobility", unreal.ComponentMobility.MOVABLE)
    sun_component.set_editor_property("intensity", 8.0)

    sky_light = unreal.EditorLevelLibrary.spawn_actor_from_class(
        unreal.SkyLight,
        unreal.Vector(0.0, 0.0, 500.0),
        unreal.Rotator(),
    )
    sky_light.set_actor_label("MovementPOC_SkyLight")
    sky_light.set_folder_path("POC/Lighting")
    sky_light.set_actor_tick_enabled(False)
    sky_component = sky_light.get_component_by_class(unreal.SkyLightComponent)
    sky_component.set_editor_property("mobility", unreal.ComponentMobility.MOVABLE)
    sky_component.set_editor_property("real_time_capture", True)
    sky_component.set_editor_property("intensity", 1.0)

    atmosphere = unreal.EditorLevelLibrary.spawn_actor_from_class(
        unreal.SkyAtmosphere,
        unreal.Vector(),
        unreal.Rotator(),
    )
    atmosphere.set_actor_label("MovementPOC_SkyAtmosphere")
    atmosphere.set_folder_path("POC/Lighting")
    atmosphere.set_actor_tick_enabled(False)

    if not unreal.EditorLevelLibrary.save_current_level():
        raise RuntimeError("Failed to save MovementPOC map")

    actor_count = len(unreal.EditorLevelLibrary.get_all_level_actors())
    report = {
        "schema": "aetheln_movement_poc_authoring_v1",
        "map": map_asset_path,
        "actor_count": actor_count,
        "geometry_actor_count": len(geometry),
        "geometry": [item[0] for item in geometry],
        "world_partition": False,
        "use_external_actors": False,
        "character_blueprint": character_asset_path,
        "game_mode_blueprint": game_mode_asset_path,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    unreal.log(f"Movement POC authoring wrote {output_path}")


def validate_target(output_path: pathlib.Path) -> None:
    character_class = _blueprint_class("/Game/POC/BP_MovementPOCCharacter")
    game_mode_class = _blueprint_class("/Game/POC/BP_MovementPOCGameMode")
    character_cdo = unreal.get_default_object(character_class)
    mesh_component = character_cdo.get_editor_property("mesh")
    movement = character_cdo.get_editor_property("character_movement")
    capsule = character_cdo.get_editor_property("capsule_component")
    camera_boom = character_cdo.get_editor_property("camera_boom")
    follow_camera = character_cdo.get_editor_property("follow_camera")

    if not unreal.EditorLevelLibrary.load_level("/Game/Maps/MovementPOC"):
        raise RuntimeError("Failed to load MovementPOC for validation")
    world = unreal.EditorLevelLibrary.get_editor_world()
    actors = unreal.EditorLevelLibrary.get_all_level_actors()
    static_actors = [
        actor for actor in actors if isinstance(actor, unreal.StaticMeshActor)
    ]
    safety_floor = next(
        (
            actor
            for actor in static_actors
            if actor.get_actor_label() == "SafetyFloor_60m"
        ),
        None,
    )
    if safety_floor is None:
        raise RuntimeError("SafetyFloor_60m is missing from MovementPOC")
    safety_floor_component = safety_floor.static_mesh_component
    static_failures = []
    for actor in static_actors:
        component = actor.static_mesh_component
        static_mesh = component.get_editor_property("static_mesh")
        if component.get_editor_property("mobility") != unreal.ComponentMobility.STATIC:
            static_failures.append(f"{actor.get_actor_label()}: mobility")
        if actor.is_actor_tick_enabled():
            static_failures.append(f"{actor.get_actor_label()}: tick")
        if (
            component.get_collision_enabled()
            == unreal.CollisionEnabled.NO_COLLISION
        ):
            static_failures.append(f"{actor.get_actor_label()}: collision disabled")
        if str(component.get_collision_profile_name()) != "BlockAll":
            static_failures.append(
                f"{actor.get_actor_label()}: collision profile "
                f"{component.get_collision_profile_name()}"
            )
        simple_collision_count = (
            unreal.EditorStaticMeshLibrary.get_simple_collision_count(
                static_mesh
            )
        )
        collision_complexity = str(
            unreal.EditorStaticMeshLibrary.get_collision_complexity(
                static_mesh
            )
        )
        if (
            simple_collision_count <= 0
            and "USE_COMPLEX_AS_SIMPLE" not in collision_complexity
        ):
            static_failures.append(
                f"{actor.get_actor_label()}: mesh has no usable collision"
            )
        if component.get_material(0).get_path_name() != (
            "/Game/LevelPrototyping/Materials/"
            "MI_PrototypeGrid_Gray.MI_PrototypeGrid_Gray"
        ):
            static_failures.append(f"{actor.get_actor_label()}: material")

    mesh_rotation = mesh_component.get_editor_property("relative_rotation")
    presentation_failures = []
    if (
        abs(mesh_rotation.pitch) > 0.01
        or abs(mesh_rotation.roll) > 0.01
        or abs(mesh_rotation.yaw + 90.0) > 0.01
    ):
        presentation_failures.append(
            f"Quinn mesh rotation is {_rotator_report(mesh_rotation)}"
        )
    expected_animation_class = (
        f"{POC_ANIMATION_BLUEPRINT_PATH}."
        "ABP_MovementPOCLocomotion_C"
    )
    assigned_animation_class = mesh_component.get_editor_property(
        "anim_class"
    ).get_path_name()
    if assigned_animation_class != expected_animation_class:
        presentation_failures.append(
            "Quinn animation class is "
            f"{assigned_animation_class}, expected "
            f"{expected_animation_class}"
        )

    poc_blend_space = unreal.EditorAssetLibrary.load_asset(
        POC_BLEND_SPACE_PATH
    )
    if not isinstance(poc_blend_space, unreal.BlendSpace):
        presentation_failures.append(
            "Movement POC locomotion BlendSpace is missing"
        )
        blend_space_weight_speed = None
        blend_space_ease_in_out = None
        lateral_sample_animations = {}
    else:
        blend_space_weight_speed = poc_blend_space.get_editor_property(
            "target_weight_interpolation_speed_per_sec"
        )
        blend_space_ease_in_out = poc_blend_space.get_editor_property(
            "target_weight_interpolation_ease_in_out"
        )
        if abs(blend_space_weight_speed - 12.0) > 0.001:
            presentation_failures.append(
                "Movement POC locomotion BlendSpace sample weight speed is "
                f"{blend_space_weight_speed}/sec, expected 12/sec"
            )
        if blend_space_ease_in_out:
            presentation_failures.append(
                "Movement POC locomotion BlendSpace still eases sample "
                "weight changes"
            )
        lateral_sample_animations = {}
        for sample in poc_blend_space.get_editor_property(
            "sample_data"
        ):
            sample_value = sample.get_editor_property("sample_value")
            sample_key = (
                round(sample_value.x),
                round(sample_value.y),
            )
            if sample_key not in POC_LATERAL_SAMPLE_REMAPS:
                continue
            animation = sample.get_editor_property("animation")
            lateral_sample_animations[
                f"{sample_key[0]},{sample_key[1]}"
            ] = (
                animation.get_path_name().split(".")[0]
                if animation is not None
                else None
            )
        expected_lateral_samples = {
            f"{direction},{speed}": path
            for (
                direction,
                speed,
            ), path in POC_LATERAL_SAMPLE_REMAPS.items()
        }
        if lateral_sample_animations != expected_lateral_samples:
            presentation_failures.append(
                "Movement POC lateral samples are "
                f"{lateral_sample_animations}, expected "
                f"{expected_lateral_samples}"
            )

    unreal.EditorAssetLibrary.load_asset(
        POC_ANIMATION_BLUEPRINT_PATH
    )
    assigned_blend_spaces = []
    for node in unreal.ObjectIterator(
        unreal.AnimGraphNode_BlendSpacePlayer
    ):
        if not node.get_path_name().startswith(
            f"{POC_ANIMATION_BLUEPRINT_PATH}."
        ):
            continue
        runtime_node = node.get_editor_property("node")
        assigned_blend_space = runtime_node.get_editor_property(
            "blend_space"
        )
        if assigned_blend_space is not None:
            assigned_blend_spaces.append(
                assigned_blend_space.get_path_name()
            )
    expected_blend_space = (
        f"{POC_BLEND_SPACE_PATH}.BS_MovementPOCLocomotion"
    )
    if assigned_blend_spaces != [expected_blend_space]:
        presentation_failures.append(
            "Movement POC animation Blueprint uses BlendSpaces "
            f"{assigned_blend_spaces}, expected [{expected_blend_space}]"
        )

    direction_selector_sources = []
    for node in unreal.ObjectIterator(unreal.K2Node_Select):
        if not node.get_path_name().startswith(
            f"{POC_ANIMATION_BLUEPRINT_PATH}."
        ):
            continue
        if ":EventGraph." not in node.get_path_name():
            continue
        return_pin = unreal.BlueprintEditorLibrary.find_output_pin(
            node,
            "ReturnValue",
        )
        return_links = (
            unreal.BlueprintGraphPinLibrary.list_connected_pins(
                return_pin
            )
        )
        if not any(
            unreal.BlueprintEditorLibrary.get_node_title(
                unreal.BlueprintGraphPinLibrary.get_owning_node(pin)
            )
            == "Set Direction"
            for pin in return_links
        ):
            continue
        index_pin = unreal.BlueprintEditorLibrary.find_input_pin(
            node,
            "Index",
        )
        for connected_pin in (
            unreal.BlueprintGraphPinLibrary.list_connected_pins(
                index_pin
            )
        ):
            direction_selector_sources.append(
                unreal.BlueprintEditorLibrary.get_node_title(
                    unreal.BlueprintGraphPinLibrary.get_owning_node(
                        connected_pin
                    )
                )
            )
    if direction_selector_sources != [
        "Get bOrientRotationToMovement"
    ]:
        presentation_failures.append(
            "Movement POC direction selector sources are "
            f"{direction_selector_sources}, expected "
            "[Get bOrientRotationToMovement]"
        )

    movement_failures = []
    rotation_rate = movement.get_editor_property("rotation_rate")
    max_acceleration = movement.get_editor_property("max_acceleration")
    ground_friction = movement.get_editor_property("ground_friction")
    air_control = movement.get_editor_property("air_control")
    falling_braking = movement.get_editor_property(
        "braking_deceleration_falling"
    )
    if abs(rotation_rate.yaw - 720.0) > 0.01:
        movement_failures.append(
            f"turn rate is {rotation_rate}, expected 720 deg/sec"
        )
    if abs(max_acceleration - 10000.0) > 0.01:
        movement_failures.append(
            f"max acceleration is {max_acceleration}, expected 10000"
        )
    if abs(ground_friction - 16.0) > 0.01:
        movement_failures.append(
            f"ground friction is {ground_friction}, expected 16"
        )
    if abs(air_control) > 0.001:
        movement_failures.append(
            f"air control is {air_control}, expected 0"
        )
    if abs(falling_braking) > 0.001:
        movement_failures.append(
            f"falling braking is {falling_braking}, expected 0"
        )

    report = {
        "schema": "aetheln_movement_poc_validation_v1",
        "map_actor_count": len(actors),
        "static_geometry_count": len(static_actors),
        "static_geometry_failures": static_failures,
        "presentation_failures": presentation_failures,
        "movement_failures": movement_failures,
        "player_start_count": sum(
            isinstance(actor, unreal.PlayerStart) for actor in actors
        ),
        "forbidden_actor_classes": sorted(
            {
                actor.get_class().get_name()
                for actor in actors
                if any(
                    token in actor.get_class().get_name()
                    for token in (
                        "NavMesh",
                        "Audio",
                        "Emitter",
                        "Niagara",
                        "Interactive",
                    )
                )
            }
        ),
        "map_game_mode": world.get_world_settings()
        .get_editor_property("default_game_mode")
        .get_path_name(),
        "poc_game_mode_default_pawn": unreal.get_default_object(game_mode_class)
        .get_editor_property("default_pawn_class")
        .get_path_name(),
        "input_component_class": character_cdo.get_editor_property(
            "override_input_component_class"
        ).get_path_name(),
        "skeletal_mesh": mesh_component.get_editor_property(
            "skeletal_mesh_asset"
        ).get_path_name(),
        "animation_class": assigned_animation_class,
        "animation_blend_spaces": assigned_blend_spaces,
        "direction_selector_sources": direction_selector_sources,
        "blend_space_weight_speed": blend_space_weight_speed,
        "blend_space_ease_in_out": blend_space_ease_in_out,
        "lateral_sample_animations": lateral_sample_animations,
        "mesh_relative_rotation": _rotator_report(mesh_rotation),
        "mesh_collision": str(mesh_component.get_collision_enabled()),
        "capsule_collision": str(capsule.get_collision_enabled()),
        "capsule_collision_profile": str(capsule.get_collision_profile_name()),
        "capsule_response_world_static": str(
            capsule.get_collision_response_to_channel(
                unreal.CollisionChannel.ECC_WORLD_STATIC
            )
        ),
        "safety_floor_mesh": safety_floor_component.get_editor_property(
            "static_mesh"
        ).get_path_name(),
        "safety_floor_collision": str(
            safety_floor_component.get_collision_enabled()
        ),
        "safety_floor_collision_profile": str(
            safety_floor_component.get_collision_profile_name()
        ),
        "safety_floor_response_pawn": str(
            safety_floor_component.get_collision_response_to_channel(
                unreal.CollisionChannel.ECC_PAWN
            )
        ),
        "capsule_radius": capsule.get_unscaled_capsule_radius(),
        "capsule_half_height": capsule.get_unscaled_capsule_half_height(),
        "walk_speed": movement.get_editor_property("max_walk_speed"),
        "jump_velocity": movement.get_editor_property("jump_z_velocity"),
        "air_control": air_control,
        "falling_braking": falling_braking,
        "max_acceleration": max_acceleration,
        "ground_friction": ground_friction,
        "rotation_rate": str(rotation_rate),
        "max_step_height": movement.get_editor_property("max_step_height"),
        "camera_arm_length": camera_boom.get_editor_property("target_arm_length"),
        "camera_collision": camera_boom.get_editor_property(
            "do_collision_test"
        ),
        "camera_lag": camera_boom.get_editor_property("enable_camera_lag"),
        "camera_fov": follow_camera.get_editor_property("field_of_view"),
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    unreal.log(f"Movement POC validation wrote {output_path}")


def main() -> None:
    _, _, params = unreal.SystemLibrary.parse_command_line(
        unreal.SystemLibrary.get_command_line()
    )
    mode = params.get("MovementPOCMode")
    if mode == "audit-source":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError("audit-source requires -MovementPOCOutput=<path>")
        audit_source(pathlib.Path(output).resolve())
    elif mode == "migrate-source":
        destination = params.get("MovementPOCDestination")
        if not destination:
            raise RuntimeError(
                "migrate-source requires -MovementPOCDestination=<Content path>"
            )
        migrate_source(pathlib.Path(destination).resolve())
    elif mode == "author-target":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError("author-target requires -MovementPOCOutput=<path>")
        author_target(pathlib.Path(output).resolve())
    elif mode == "validate-target":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError("validate-target requires -MovementPOCOutput=<path>")
        validate_target(pathlib.Path(output).resolve())
    elif mode == "repair-target-collision":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError(
                "repair-target-collision requires -MovementPOCOutput=<path>"
            )
        repair_target_collision(pathlib.Path(output).resolve())
    elif mode == "repair-target-geometry":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError(
                "repair-target-geometry requires -MovementPOCOutput=<path>"
            )
        repair_target_geometry(pathlib.Path(output).resolve())
    elif mode == "repair-target-presentation":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError(
                "repair-target-presentation requires "
                "-MovementPOCOutput=<path>"
            )
        repair_target_presentation(pathlib.Path(output).resolve())
    elif mode == "audit-target-animation":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError(
                "audit-target-animation requires -MovementPOCOutput=<path>"
            )
        audit_target_animation(pathlib.Path(output).resolve())
    elif mode == "repair-target-lateral-animation":
        output = params.get("MovementPOCOutput")
        if not output:
            raise RuntimeError(
                "repair-target-lateral-animation requires "
                "-MovementPOCOutput=<path>"
            )
        repair_target_lateral_animation(pathlib.Path(output).resolve())
    else:
        raise RuntimeError(
            "Expected -MovementPOCMode=audit-source, migrate-source, "
            "author-target, validate-target, repair-target-collision, "
            "repair-target-geometry, repair-target-presentation, "
            "audit-target-animation, or repair-target-lateral-animation"
        )

    unreal.SystemLibrary.quit_editor()


main()
