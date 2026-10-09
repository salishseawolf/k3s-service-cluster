{{/*
Sources allowed to reach Gitea's token paths (git smart-HTTP, /api, /v2)
without forward-auth: the admin ranges plus the pod network, rendered as
ClientIP() arguments. Prefixed "k3s." so it can't collide with the gitea
subchart's own "gitea.*" templates (named templates are global).
*/}}
{{- define "k3s.gitea.tokenSourceRanges" -}}
{{- $ranges := concat .Values.adminSourceRanges .Values.inClusterSourceRanges -}}
{{- $quoted := list -}}
{{- range $ranges }}{{ $quoted = append $quoted (printf "`%s`" .) }}{{ end -}}
{{- join ", " $quoted -}}
{{- end -}}
