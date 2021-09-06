from __future__ import annotations

from dataclasses import dataclass
from dataclasses import field
from dataclasses import replace
from typing import Dict
from typing import Iterable
from typing import List
from typing import NewType
from typing import Set
from typing import TypeVar

import pandas as pd  # type: ignore [import]

T = TypeVar('T')

ComponentType = NewType('ComponentType', str)
ComponentId = NewType('ComponentId', str)
ComponentName = NewType('ComponentName', str)
BikeId = NewType('BikeId', str)
BikeName = NewType('BikeName', str)
HashTag = NewType('HashTag', str)

ComponentMap = Dict[ComponentType, ComponentId]
Mapping = Dict[T, ComponentMap]


@dataclass(frozen=True)
class Component:
    ident: ComponentId
    name: ComponentName
    distance: float = 0  # meters
    time: float = 0  # seconds

    def add_usage(self, usage: Usage) -> Component:
        return replace(
            self,
            distance=self.distance + usage.distances.get(self.ident, 0),
            time=self.time + usage.times.get(self.ident, 0))


@dataclass(frozen=True)
class Rule:
    bikes: Mapping[BikeId] = field(default_factory=dict)
    hashtags: Mapping[HashTag] = field(default_factory=dict)
    since: pd.Timestamp = pd.to_datetime(0, utc=True)

    def __add__(self, other):
        """
        Combine two rules. The second rule's since must be later than the first. Component mappings
        in the second rule then override those in the first. Additionally, components newly assigned
        to another bike are automatically removed from the old one.
        """
        if not isinstance(other, Rule):
            return NotImplemented
        if other.since < self.since:
            return NotImplemented

        other_components = {c for m in other.bikes.values() for c in m.values()}
        bikes = prune_mapping(update_mappings(filter_mapping(self.bikes, other_components), other.bikes))
        hashtags = prune_mapping(update_mappings(self.hashtags, other.hashtags))
        return replace(other, bikes=bikes, hashtags=hashtags)


def prune_mapping(m: Mapping[T]) -> Mapping[T]:
    """Prune mapping—drop null/None components and empty dicts."""
    return {a: b for a, b in ((a, {c: d for c, d in b.items() if d}) for a, b in m.items()) if b}


def update_mappings(m1: Mapping[T], m2: Mapping[T]) -> Mapping[T]:
    """Override component mappings in m1 by those in m2."""
    return {a: {**m1.get(a, {}), **m2.get(a, {})} for a in m1.keys() | m2.keys()}


def filter_mapping(m: Mapping[T], f: Set[T]) -> Mapping[T]:
    """Remove components from a mapping."""
    return {a: {c: d for c, d in b.items() if d not in f} for a, b in m.items()}


@dataclass(frozen=True)
class Rules:
    bike_names: Dict[BikeId, BikeName]
    components: List[Component]
    rules: List[Rule]


@dataclass
class Usage:
    distances: Dict[ComponentId, float] = field(default_factory=dict)
    times: Dict[ComponentId, float] = field(default_factory=dict)

    @staticmethod
    def from_activity(components: Iterable[ComponentId], distance: float, time: float):
        return Usage(
            distances={c: distance for c in components},
            times={c: time for c in components})

    def __iadd__(self, other):
        for k, v in other.distances.items():
            self.distances[k] = self.distances.get(k, 0) + v
        for k, v in other.times.items():
            self.times[k] = self.times.get(k, 0) + v
        return self

    def __add__(self, other):
        self_copy = replace(self, distances=self.distances.copy(), times=self.times.copy())
        self_copy += other
        return self_copy
