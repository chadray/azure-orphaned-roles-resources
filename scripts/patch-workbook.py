#!/usr/bin/env python3
"""Patch the vendored Azure Orphaned Resources workbook to add a Security tab
for orphaned RBAC role assignments queried from Log Analytics."""

import json
import uuid
import sys
from pathlib import Path


def new_guid():
    return str(uuid.uuid4())


# ── Workspace parameter (Log Analytics workspace picker) ──
WORKSPACE_PARAMETER = {
    "id": new_guid(),
    "version": "KqlParameterItem/1.0",
    "name": "Workspace",
    "label": "Log Analytics Workspace",
    "type": 5,
    "isRequired": False,
    "query": (
        "resources\n"
        "| where type =~ \"microsoft.operationalinsights/workspaces\"\n"
        "| project id, name, resourceGroup, subscriptionId, location\n"
        "| order by name asc"
    ),
    "crossComponentResources": ["{Subscription}"],
    "typeSettings": {
        "resourceTypeFilter": {
            "microsoft.operationalinsights/workspaces": True
        },
        "additionalResourceOptions": ["value::1"],
        "showDefault": False
    },
    "queryType": 1,
    "resourceType": "microsoft.resourcegraph/resources"
}

# ── Main tab link for Security ──
SECURITY_TAB_LINK = {
    "id": new_guid(),
    "cellValue": "mainTab",
    "linkTarget": "parameter",
    "linkLabel": "Security",
    "subTarget": "security",
    "style": "link"
}

# ── Overview tile for orphaned role assignments ──
OVERVIEW_TILE = {
    "type": 3,
    "content": {
        "version": "KqlItem/1.0",
        "query": (
            "OrphanedRoleScanSummary_CL\n"
            "| summarize arg_max(TimeGenerated, *)\n"
            "| project type = \"Orphaned Role Assignments\", total_count = tolong(TotalOrphaned)\n"
            "| union (datatable(type:string, total_count:long) [\"Orphaned Role Assignments\", 0])\n"
            "| summarize total_count = max(total_count) by type"
        ),
        "size": 3,
        "title": " ",
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces",
        "crossComponentResources": ["{Workspace}"],
        "visualization": "tiles",
        "tileSettings": {
            "titleContent": {
                "columnMatch": "type",
                "formatter": 1,
                "formatOptions": {"showIcon": True}
            },
            "leftContent": {
                "columnMatch": "total_count",
                "formatter": 12,
                "formatOptions": {"palette": "auto"}
            },
            "showBorder": True
        }
    },
    "conditionalVisibility": {
        "parameterName": "Workspace",
        "comparison": "isNotEqualTo",
        "value": ""
    },
    "customWidth": "16.5",
    "name": "query - Overview - Orphaned Role Assignments Count"
}

# ── KQL queries for the Security tab ──
LAST_SCAN_QUERY = (
    "OrphanedRoleScanSummary_CL\n"
    "| summarize arg_max(TimeGenerated, *)\n"
    "| project LastScan=TimeGenerated,\n"
    "          ScanScope,\n"
    "          TotalOrphaned,\n"
    "          Confirmed=ConfirmedCount,\n"
    "          Suspected=SuspectedCount,\n"
    "          OrphanedPrincipals=OrphanedPrincipalCount,\n"
    "          OrphanedScopes=OrphanedScopeCount,\n"
    "          ScanId"
)

LATEST_SCAN_ID_QUERY = (
    "OrphanedRoleScanSummary_CL\n"
    "| summarize arg_max(TimeGenerated, ScanId)\n"
    "| project ScanId"
)

TOTAL_COUNT_QUERY = (
    "OrphanedRoleScanSummary_CL\n"
    "| summarize arg_max(TimeGenerated, *)\n"
    "| project type = \"microsoft.authorization/roleassignments\", total_count = tolong(TotalOrphaned)\n"
    "| union (datatable(type:string, total_count:long) [\"microsoft.authorization/roleassignments\", 0])\n"
    "| summarize total_count = max(total_count) by type"
)

BY_REASON_QUERY = (
    "let latestScan = toscalar(OrphanedRoleScanSummary_CL | summarize arg_max(TimeGenerated, ScanId) | project ScanId);\n"
    "OrphanedRoleAssignments_CL\n"
    "| where ScanId == latestScan\n"
    "| extend reason = split(OrphanReasons, ', ')\n"
    "| mv-expand reason to typeof(string)\n"
    "| summarize count() by reason"
)

BY_STATUS_QUERY = (
    "let latestScan = toscalar(OrphanedRoleScanSummary_CL | summarize arg_max(TimeGenerated, ScanId) | project ScanId);\n"
    "OrphanedRoleAssignments_CL\n"
    "| where ScanId == latestScan\n"
    "| summarize count() by DetectionStatus"
)

BY_ROLE_QUERY = (
    "let latestScan = toscalar(OrphanedRoleScanSummary_CL | summarize arg_max(TimeGenerated, ScanId) | project ScanId);\n"
    "OrphanedRoleAssignments_CL\n"
    "| where ScanId == latestScan\n"
    "| summarize count() by RoleDefinitionName"
)

DETAIL_TABLE_QUERY = (
    "let latestScan = toscalar(OrphanedRoleScanSummary_CL | summarize arg_max(TimeGenerated, ScanId) | project ScanId);\n"
    "OrphanedRoleAssignments_CL\n"
    "| where ScanId == latestScan\n"
    "| extend Details = pack_all()\n"
    "| project RoleDefinitionName, PrincipalId, PrincipalType,\n"
    "          DisplayName, Scope, OrphanReasons,\n"
    "          DetectionStatus, CanSafelyDelete,\n"
    "          ValidationNotes, ScannedAt, Details"
)


def build_security_tab():
    """Build the complete Security tab group."""
    return {
        "type": 12,
        "content": {
            "version": "NotebookGroup/1.0",
            "groupType": "editable",
            "items": [
                # Info banner
                {
                    "type": 1,
                    "content": {
                        "json": (
                            "ℹ️ **RBAC orphan data is generated by the Function App scan, not real-time Resource Graph.** "
                            "Results reflect the most recent scan run. Select a Log Analytics Workspace above to view data."
                        ),
                        "style": "info"
                    },
                    "conditionalVisibility": {
                        "parameterName": "Workspace",
                        "comparison": "isNotEqualTo",
                        "value": ""
                    },
                    "name": "text - Security - Info Banner"
                },
                # No workspace warning
                {
                    "type": 1,
                    "content": {
                        "json": (
                            "⚠️ **Select a Log Analytics Workspace** from the filter bar above to view orphaned role assignment data.\n\n"
                            "The workspace must contain the `OrphanedRoleAssignments_CL` and `OrphanedRoleScanSummary_CL` "
                            "custom log tables populated by the orphaned-roles scanner Function App."
                        ),
                        "style": "warning"
                    },
                    "conditionalVisibility": {
                        "parameterName": "Workspace",
                        "comparison": "isEqualTo",
                        "value": ""
                    },
                    "name": "text - Security - No Workspace Warning"
                },
                # Sub-tab nav
                {
                    "type": 11,
                    "content": {
                        "version": "LinkItem/1.0",
                        "style": "tabs",
                        "links": [
                            {
                                "id": new_guid(),
                                "cellValue": "securityTab",
                                "linkTarget": "parameter",
                                "linkLabel": "Orphaned Role Assignments",
                                "subTarget": "roleassignments",
                                "style": "link",
                                "linkIsContextBlade": True
                            }
                        ]
                    },
                    "conditionalVisibility": {
                        "parameterName": "Workspace",
                        "comparison": "isNotEqualTo",
                        "value": ""
                    },
                    "name": "links - Security Tabs"
                },
                # Role assignments content group
                {
                    "type": 12,
                    "content": {
                        "version": "NotebookGroup/1.0",
                        "groupType": "editable",
                        "items": [
                            # Title
                            {
                                "type": 1,
                                "content": {"json": "# Orphaned Role Assignments"},
                                "name": "text - Title - Role Assignments"
                            },
                            # Description
                            {
                                "type": 1,
                                "content": {
                                    "json": (
                                        "[Role Assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments) "
                                        "where the assigned principal (user, group, service principal, managed identity) has been deleted from "
                                        "Entra ID, or the target scope (resource group, resource) no longer exists."
                                    ),
                                    "style": "upsell"
                                },
                                "name": "text - Info - Role Assignments"
                            },
                            # Last scan info
                            {
                                "type": 3,
                                "content": {
                                    "version": "KqlItem/1.0",
                                    "query": LAST_SCAN_QUERY,
                                    "size": 4,
                                    "title": "Latest Scan",
                                    "noDataMessage": "No scan data found. Run the Function App scanner to populate data.",
                                    "queryType": 0,
                                    "resourceType": "microsoft.operationalinsights/workspaces",
                                    "crossComponentResources": ["{Workspace}"],
                                    "visualization": "table",
                                    "gridSettings": {
                                        "labelSettings": [
                                            {"columnId": "LastScan", "label": "Last Scan"},
                                            {"columnId": "ScanScope", "label": "Scope"},
                                            {"columnId": "TotalOrphaned", "label": "Total"},
                                            {"columnId": "Confirmed", "label": "Confirmed"},
                                            {"columnId": "Suspected", "label": "Suspected"},
                                            {"columnId": "OrphanedPrincipals", "label": "Orphaned Principals"},
                                            {"columnId": "OrphanedScopes", "label": "Orphaned Scopes"},
                                            {"columnId": "ScanId", "label": "Scan ID"}
                                        ]
                                    }
                                },
                                "name": "query - Last Scan Summary"
                            },
                            # Total count tile
                            {
                                "type": 3,
                                "content": {
                                    "version": "KqlItem/1.0",
                                    "query": TOTAL_COUNT_QUERY,
                                    "size": 4,
                                    "title": "Total",
                                    "queryType": 0,
                                    "resourceType": "microsoft.operationalinsights/workspaces",
                                    "crossComponentResources": ["{Workspace}"],
                                    "visualization": "tiles",
                                    "tileSettings": {
                                        "titleContent": {
                                            "columnMatch": "type",
                                            "formatter": 1,
                                            "formatOptions": {"showIcon": True}
                                        },
                                        "leftContent": {
                                            "columnMatch": "total_count",
                                            "formatter": 12,
                                            "formatOptions": {"palette": "auto"}
                                        },
                                        "showBorder": False,
                                        "size": "auto"
                                    }
                                },
                                "customWidth": "15",
                                "name": "query - Role Assignment Count"
                            },
                            # Pie chart: by reason
                            {
                                "type": 3,
                                "content": {
                                    "version": "KqlItem/1.0",
                                    "query": BY_REASON_QUERY,
                                    "size": 4,
                                    "title": "Count by Orphan Reason",
                                    "noDataMessage": "No data",
                                    "queryType": 0,
                                    "resourceType": "microsoft.operationalinsights/workspaces",
                                    "crossComponentResources": ["{Workspace}"],
                                    "visualization": "piechart",
                                    "chartSettings": {"showMetrics": False, "showLegend": True}
                                },
                                "customWidth": "25",
                                "name": "query - Role Assignments by Reason"
                            },
                            # Pie chart: by status
                            {
                                "type": 3,
                                "content": {
                                    "version": "KqlItem/1.0",
                                    "query": BY_STATUS_QUERY,
                                    "size": 4,
                                    "title": "Count by Detection Status",
                                    "noDataMessage": "No data",
                                    "queryType": 0,
                                    "resourceType": "microsoft.operationalinsights/workspaces",
                                    "crossComponentResources": ["{Workspace}"],
                                    "visualization": "piechart",
                                    "chartSettings": {"showMetrics": False, "showLegend": True}
                                },
                                "customWidth": "25",
                                "name": "query - Role Assignments by Status"
                            },
                            # Pie chart: by role
                            {
                                "type": 3,
                                "content": {
                                    "version": "KqlItem/1.0",
                                    "query": BY_ROLE_QUERY,
                                    "size": 4,
                                    "title": "Count by Role",
                                    "noDataMessage": "No data",
                                    "queryType": 0,
                                    "resourceType": "microsoft.operationalinsights/workspaces",
                                    "crossComponentResources": ["{Workspace}"],
                                    "visualization": "piechart",
                                    "chartSettings": {"showMetrics": False, "showLegend": True}
                                },
                                "customWidth": "25",
                                "name": "query - Role Assignments by Role"
                            },
                            # Detail table
                            {
                                "type": 3,
                                "content": {
                                    "version": "KqlItem/1.0",
                                    "query": DETAIL_TABLE_QUERY,
                                    "size": 3,
                                    "title": "Orphaned Role Assignments (Latest Scan)",
                                    "noDataMessage": "No orphaned role assignments found in the latest scan.",
                                    "showExportToExcel": True,
                                    "queryType": 0,
                                    "resourceType": "microsoft.operationalinsights/workspaces",
                                    "crossComponentResources": ["{Workspace}"],
                                    "visualization": "table",
                                    "gridSettings": {
                                        "formatters": [
                                            {"columnMatch": "Details", "formatter": 7, "formatOptions": {
                                                "linkTarget": "CellDetails",
                                                "linkLabel": "🔍 View Details",
                                                "linkIsContextBlade": True
                                            }},
                                            {"columnMatch": "CanSafelyDelete", "formatter": 18,
                                             "formatOptions": {
                                                "thresholdsOptions": "icons",
                                                "thresholdsGrid": [
                                                    {"operator": "==", "thresholdValue": "true",
                                                     "representation": "success", "text": "Yes"},
                                                    {"operator": "==", "thresholdValue": "false",
                                                     "representation": "warning", "text": "No"},
                                                    {"operator": "Default",
                                                     "representation": "unknown", "text": "{0}"}
                                                ]
                                            }}
                                        ],
                                        "rowLimit": 1000,
                                        "filter": True,
                                        "labelSettings": [
                                            {"columnId": "RoleDefinitionName", "label": "Role"},
                                            {"columnId": "PrincipalId", "label": "Principal ID"},
                                            {"columnId": "PrincipalType", "label": "Principal Type"},
                                            {"columnId": "DisplayName", "label": "Display Name"},
                                            {"columnId": "Scope", "label": "Scope"},
                                            {"columnId": "OrphanReasons", "label": "Orphan Reason"},
                                            {"columnId": "DetectionStatus", "label": "Status"},
                                            {"columnId": "CanSafelyDelete", "label": "Safe to Delete"},
                                            {"columnId": "ValidationNotes", "label": "Notes"},
                                            {"columnId": "ScannedAt", "label": "Scanned At"},
                                            {"columnId": "Details", "label": "Details"}
                                        ]
                                    }
                                },
                                "name": "query - Orphaned Role Assignments Detail"
                            }
                        ]
                    },
                    "conditionalVisibilities": [
                        {
                            "parameterName": "securityTab",
                            "comparison": "isEqualTo",
                            "value": "roleassignments"
                        },
                        {
                            "parameterName": "Workspace",
                            "comparison": "isNotEqualTo",
                            "value": ""
                        }
                    ],
                    "name": "group - Security - Role Assignments"
                }
            ]
        },
        "conditionalVisibility": {
            "parameterName": "mainTab",
            "comparison": "isEqualTo",
            "value": "security"
        },
        "name": "group - Security"
    }


def patch_workbook(workbook: dict) -> dict:
    """Apply Security tab patches to the workbook."""
    items = workbook["items"]

    # 1. Add Workspace parameter to the parameters panel
    for item in items:
        if item.get("type") == 9 and "parameters" in item.get("content", {}):
            params = item["content"]["parameters"]
            # Add after existing parameters
            if not any(p.get("name") == "Workspace" for p in params):
                params.append(WORKSPACE_PARAMETER)
            break

    # 2. Add Security link to main tab navigation
    for item in items:
        if item.get("type") == 11 and item.get("name", "").startswith("links"):
            links = item["content"]["links"]
            if not any(l.get("subTarget") == "security" for l in links):
                links.append(SECURITY_TAB_LINK)
            break

    # 3. Add overview tile for orphaned role assignments
    #    Find the Overview group and append the tile
    for item in items:
        if (item.get("type") == 12 and
            item.get("conditionalVisibility", {}).get("value") == "overview"):
            overview_items = item["content"]["items"]
            if not any("Orphaned Role Assignments Count" in i.get("name", "") for i in overview_items):
                overview_items.append(OVERVIEW_TILE)
            break

    # 4. Add the Security tab group
    if not any(i.get("name") == "group - Security" for i in items):
        items.append(build_security_tab())

    return workbook


def main():
    workbook_path = Path(__file__).parent.parent / "workbooks" / "azure-orphaned-resources.workbook"

    if not workbook_path.exists():
        print(f"Error: Workbook not found at {workbook_path}", file=sys.stderr)
        sys.exit(1)

    with open(workbook_path, encoding="utf-8") as f:
        workbook = json.load(f)

    workbook = patch_workbook(workbook)

    with open(workbook_path, "w", encoding="utf-8") as f:
        json.dump(workbook, f, indent=2, ensure_ascii=False)

    print(f"✅  Workbook patched: {workbook_path}")
    print(f"    - Added Workspace parameter")
    print(f"    - Added Security tab link")
    print(f"    - Added overview tile for orphaned role assignments")
    print(f"    - Added Security tab group with RBAC content")


if __name__ == "__main__":
    main()
