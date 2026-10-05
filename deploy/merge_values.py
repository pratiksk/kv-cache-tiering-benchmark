"""Merge a scenario overlay into base.yaml and print the result.

Helm replaces lists instead of merging them, and the engines are a list
(servingEngineSpec.modelSpec). So an overlay's `engine:` block is deep-merged into
every engine entry here, and everything else is deep-merged at the top level.
`podB` and `bench` are read by deploy.sh / the Makefile and dropped from the values.
"""
import sys

import yaml


def merge(base, over):
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            merge(base[k], v)
        else:
            base[k] = v
    return base


base = yaml.safe_load(open(sys.argv[1]))
over = yaml.safe_load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
engine = over.pop("engine", {})
for spec in base["servingEngineSpec"]["modelSpec"]:
    merge(spec, yaml.safe_load(yaml.safe_dump(engine)))  # fresh copy per engine
over.pop("podB", None)
over.pop("bench", None)
print(yaml.safe_dump(merge(base, over), sort_keys=False))
