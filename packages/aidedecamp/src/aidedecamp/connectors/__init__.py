"""Workspace + Slack connectors (design doc 4.3, 4.4, 4.7).

Define a small internal interface (list_events, send_draft, create_hold, ...)
with two Workspace implementations behind it: one backed by Google's managed MCP
servers, one backed by direct OAuth + google-api-python-client. Which one runs is
a config choice (config.ConnectorMode), so a TELUS 'no' on MCP is not a rewrite.

Slack is built on Bolt's Assistant class rather than a raw Events API bot.
"""
