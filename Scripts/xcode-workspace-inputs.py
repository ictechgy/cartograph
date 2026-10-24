#!/usr/bin/env python3
"""Read finite workspace containers and namespace PBX identities without executing project code."""
import copy
from pathlib import PurePosixPath
import xml.etree.ElementTree as ET


class WorkspaceError(ValueError):
    pass


def require(value, message):
    if not value:
        raise WorkspaceError(message)


def relative(value):
    return isinstance(value, str) and 0 < len(value.encode()) <= 4096 and not any(
        c in value for c in ("\\", ":", "$")) and all(ord(c) >= 32 for c in value) and all(
        p not in ("", ".", "..") for p in value.split("/"))


def projects(data):
    require(len(data) <= 1024 * 1024 and b"<!DOCTYPE" not in data.upper() and b"<!ENTITY" not in data.upper(),
            "Workspace XML byte/entity boundary exceeded")
    root = ET.fromstring(data)
    require(root.tag == "Workspace", "Expected explicit Workspace metadata")
    result, pending, count = [], [(root, "", 0)], 0
    while pending:
        node, parent, depth = pending.pop()
        require(depth <= 32, "Workspace group depth budget exceeded")
        for child in node:
            count += 1
            require(count <= 256 and child.tag in ("Group", "FileRef"), "Unsupported workspace entry or entry budget")
            location = child.get("location", "")
            kind, separator, value = location.partition(":")
            require(separator and kind in ("group", "container") and relative(value),
                    "Workspace references must remain explicit and local")
            path = "/".join(x for x in (parent if kind == "group" else "", value) if x)
            if child.tag == "Group":
                pending.append((child, path, depth + 1))
            else:
                require(not list(child) and path.endswith(".xcodeproj"), "Only explicit Xcode project workspace references are supported")
                result.append(path)
    require(1 <= len(result) <= 32 and len(set(result)) == len(result), "Workspace requires 1...32 unique projects")
    return sorted(result)


REFERENCE_KEYS = {"children", "files", "buildPhases", "dependencies", "targets", "buildConfigurationList",
                  "buildConfigurations", "productReference", "mainGroup", "productRefGroup", "fileRef",
                  "productRef", "package", "containerPortal", "targetProxy", "target", "remoteRef"}


def merge(plists):
    """Resolve explicit project/proxy edges, then run the ordinary PBX safety parser on the result."""
    require(1 <= len(plists) <= 32, "Workspace project count budget exceeded")
    all_objects, target_ids, main_groups, path_maps = {}, [], [], {}
    for path, plist in sorted(plists.items()):
        require(relative(path) and path.endswith(".xcodeproj"), "Invalid workspace project path")
        objects = copy.deepcopy(plist.get("objects", {}))
        project = objects.get(plist.get("rootObject"), {})
        require(project.get("isa") == "PBXProject" and not project.get("projectDirPath") and not project.get("projectRoot")
                and not project.get("packageReferences"),
                "Unsupported project source root")
        require(len(objects) <= 50000, "Project object budget exceeded")
        require(isinstance(project.get("targets"), list) and len(set(project["targets"])) == len(project["targets"]),
                "Duplicate or missing project target identities")
        # Source-root paths are relative to the containing project directory, not to the workspace file.
        prefix = str(PurePosixPath(path).parent)
        prefix = "" if prefix == "." else prefix
        paths, seen, pending = {}, set(), [(project.get("mainGroup"), "", 0)]
        while pending:
            ident, parent, depth = pending.pop()
            require(ident in objects and ident not in seen and depth <= 128, "Missing/shared/cyclic project group")
            seen.add(ident)
            obj = objects[ident]
            tree, component = obj.get("sourceTree", "<group>"), obj.get("path", "")
            if tree not in ("<group>", "SOURCE_ROOT"):
                continue
            require(not component or relative(component), "External project path")
            combined = "/".join(x for x in ("" if tree == "SOURCE_ROOT" else parent, component) if x)
            if obj.get("isa") == "PBXGroup":
                pending += [(x, combined, depth + 1) for x in obj.get("children", [])]
            elif obj.get("isa") == "PBXFileReference" and combined:
                paths[ident] = "/".join(x for x in (prefix, combined) if x)
        path_maps[path] = paths
        project_refs = project.get("projectReferences", [])
        require(isinstance(project_refs, list), "Malformed project references")
        portals = {}
        for item in project_refs:
            require(set(item) == {"ProjectRef", "ProductGroup"}, "Unsupported cross-project reference metadata")
            portal = item["ProjectRef"]
            remote = paths.get(portal)
            require(remote in plists and remote != path and portal not in portals,
                    "Project reference is absent, duplicate, self-referential or outside the workspace")
            require(objects.get(item["ProductGroup"], {}).get("isa") == "PBXGroup", "Missing project product group")
            portals[portal] = remote
        remotes = {}
        for ident, obj in objects.items():
            if obj.get("isa") != "PBXContainerItemProxy":
                continue
            portal = obj.get("containerPortal")
            remote_path = path if portal == plist.get("rootObject") else portals.get(portal)
            require(remote_path in plists and obj.get("proxyType") in ("1", "2", 1, 2), "Unbound cross-project proxy")
            remote_objects = plists[remote_path]["objects"]
            remote_project = remote_objects[plists[remote_path]["rootObject"]]
            remote_id = obj.get("remoteGlobalIDString")
            kind = int(obj["proxyType"])
            expected = remote_project.get("targets", []) if kind == 1 else [
                remote_objects[x].get("productReference") for x in remote_project.get("targets", [])]
            require(remote_id in expected, "Proxy does not identify a native target or its declared product")
            remotes[ident] = (kind, remote_path + "::" + remote_id, remote_objects.get(remote_id, {}))
        proxy_products = {}
        for ident, obj in objects.items():
            if obj.get("isa") == "PBXReferenceProxy":
                proxy = remotes.get(obj.get("remoteRef"))
                require(proxy and proxy[0] == 2 and obj.get("sourceTree") == "BUILT_PRODUCTS_DIR"
                        and obj.get("path") == proxy[2].get("path"), "Ambiguous cross-project product proxy")
                proxy_products[ident] = proxy[1]
        def remap(value, key=None):
            if isinstance(value, dict):
                return {k: remap(v, k) for k, v in value.items()}
            if isinstance(value, list):
                return [remap(v, key) for v in value]
            if key in REFERENCE_KEYS and isinstance(value, str) and value in objects:
                return proxy_products.get(value, path + "::" + value)
            return value
        for ident, obj in objects.items():
            if obj.get("isa") in ("PBXProject", "PBXContainerItemProxy", "PBXReferenceProxy"):
                continue
            updated = remap(obj)
            if obj.get("isa") == "PBXGroup":
                updated["children"] = [remap(x, "children") for x in obj.get("children", [])
                                       if objects.get(x, {}).get("isa") != "PBXReferenceProxy"]
            if obj.get("isa") == "PBXTargetDependency":
                proxy = remotes.get(obj.get("targetProxy"))
                direct = obj.get("target")
                require(direct in project.get("targets", []) or proxy and proxy[0] == 1,
                        "Dependency has no explicit local/workspace native target")
                if proxy:
                    require(not direct or path + "::" + direct == proxy[1], "Target dependency and proxy disagree")
                    updated["target"] = proxy[1]
                updated.pop("targetProxy", None)
            if ident == project.get("mainGroup"):
                require(obj.get("isa") == "PBXGroup" and not obj.get("path"), "Project main group must use its source root")
                if prefix:
                    updated.update({"path": prefix, "sourceTree": "SOURCE_ROOT"})
            elif obj.get("sourceTree") == "SOURCE_ROOT" and obj.get("path"):
                require(relative(obj["path"]), "Invalid source-root path")
                updated["path"] = "/".join(x for x in (prefix, obj["path"]) if x)
            all_objects[path + "::" + ident] = updated
        target_ids += [path + "::" + x for x in project.get("targets", [])]
        main_groups.append(path + "::" + project["mainGroup"])
    require(len(all_objects) <= 50000 and 0 < len(target_ids) <= 1000, "Combined workspace object/target budget exceeded")
    all_objects["workspace-root"] = {"isa": "PBXProject", "targets": sorted(target_ids), "mainGroup": "workspace-group"}
    all_objects["workspace-group"] = {"isa": "PBXGroup", "children": main_groups, "sourceTree": "<group>"}
    return {"rootObject": "workspace-root", "objects": all_objects}
