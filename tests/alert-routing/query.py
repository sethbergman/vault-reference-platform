#!/usr/bin/env python3
"""Answer one question about the Alertmanager config, for run-tests.sh.

Usage: query.py <alertmanager.yml> <rules.yml> <question>

The YAML reading lives here so the test file holds assertions rather than
parsing. Each question prints a single line; "none" means "no offenders",
which lets the caller assert on an exact string instead of an exit code
and get the offending names in the failure message for free.
"""

import sys

import yaml


def matcher_value(matcher, key):
    """Value from a matcher like 'severity="critical"', or None."""
    prefix = key + "="
    if not matcher.startswith(prefix):
        return None
    return matcher[len(prefix):].strip('"')


def sub_route(am, severity):
    """The child route matching a severity, or {}."""
    for route in am["route"].get("routes", []):
        for matcher in route.get("matchers", []):
            if matcher_value(matcher, "severity") == severity:
                return route
    return {}


def alert_rules(rules):
    for group in rules.get("groups", []):
        for rule in group.get("rules", []):
            if "alert" in rule:
                yield rule


def joined(names):
    return ",".join(sorted(set(names))) or "none"


def answer(question, am, rules):
    if question == "alerts-without-severity":
        return joined(r["alert"] for r in alert_rules(rules)
                      if not r.get("labels", {}).get("severity"))

    if question == "severities-without-route":
        used = {r["labels"]["severity"] for r in alert_rules(rules)
                if r.get("labels", {}).get("severity")}
        routed = set()
        for route in am["route"].get("routes", []):
            for matcher in route.get("matchers", []):
                value = matcher_value(matcher, "severity")
                if value:
                    routed.add(value)
        return joined(used - routed)

    if question == "critical-group-wait":
        return str(sub_route(am, "critical").get("group_wait"))
    if question == "critical-repeat-interval":
        return str(sub_route(am, "critical").get("repeat_interval"))
    if question == "warning-repeat-interval":
        return str(sub_route(am, "warning").get("repeat_interval"))

    if question == "group-by-has-instance":
        return str("instance" in am["route"].get("group_by", []))
    if question == "group-by-has-alertname":
        return str("alertname" in am["route"].get("group_by", []))

    if question == "inhibit-unknown-alertnames":
        known = {r["alert"] for r in alert_rules(rules)}
        unknown = []
        for rule in am.get("inhibit_rules", []):
            for key in ("source_matchers", "target_matchers"):
                for matcher in rule.get(key, []):
                    name = matcher_value(matcher, "alertname")
                    if name and name not in known:
                        unknown.append(name)
        return joined(unknown)

    if question == "inhibit-self-referential":
        offenders = []
        for rule in am.get("inhibit_rules", []):
            source = sorted(rule.get("source_matchers", []))
            target = sorted(rule.get("target_matchers", []))
            if source and source == target:
                offenders.append(",".join(source))
        return joined(offenders)

    if question == "routes-to-undefined-receivers":
        defined = {r["name"] for r in am.get("receivers", [])}
        used = {am["route"]["receiver"]}
        for route in am["route"].get("routes", []):
            used.add(route["receiver"])
        return joined(used - defined)

    if question == "receivers-with-no-destination":
        # A receiver whose only *_configs list is empty parses, validates,
        # and delivers nowhere. That was the previous configuration.
        empty = []
        for receiver in am.get("receivers", []):
            configs = [v for k, v in receiver.items() if k.endswith("_configs")]
            if not any(configs):
                empty.append(receiver["name"])
        return joined(empty)

    raise SystemExit("unknown question: %s" % question)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    am_path, rules_path, question = sys.argv[1:4]
    with open(am_path, encoding="utf-8") as fh:
        am = yaml.safe_load(fh)
    with open(rules_path, encoding="utf-8") as fh:
        rules = yaml.safe_load(fh)
    print(answer(question, am, rules))


if __name__ == "__main__":
    main()
