"""LangGraph orchestration (design doc 4.2).

Model each workflow as a small, single-purpose, checkpointed graph rather than
one giant graph: a triage graph per incoming item, a draft-and-approve graph, a
scheduling graph, and a daily-brief graph. Checkpointing lets a 'waiting for your
approval' state survive a restart; the human-in-the-loop interrupt/resume
primitives are what make rung-2 autonomy (propose, wait) work.

Consult ``autonomy.py`` before any action leaves a graph.
"""
