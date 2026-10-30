{{- define "gvisor-installer.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 50 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 50 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "gvisor-installer.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gvisor-installer.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: installer
{{- end }}

{{- define "gvisor-installer.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default (regexReplaceAll "\\+.*$" .Chart.Version "") }}
{{- end }}

{{/* The installer's environment, shared by install and uninstall. */}}
{{- define "gvisor-installer.env" -}}
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
- name: GVISOR_HANDLER
  value: {{ .Values.gvisor.handler | quote }}
- name: GVISOR_REMOVE_HANDLERS
  value: {{ join " " .Values.gvisor.removeHandlers | quote }}
- name: GVISOR_PLATFORM
  value: {{ .Values.gvisor.platform | quote }}
- name: GVISOR_RUNSC_FLAGS
  value: {{ include "gvisor-installer.runscFlags" . | quote }}
- name: GVISOR_CRI
  value: {{ .Values.gvisor.cri | quote }}
- name: GVISOR_RESTART_CRI
  value: {{ .Values.gvisor.restartCRI | quote }}
- name: GVISOR_PREFIX
  value: {{ .Values.gvisor.prefix | quote }}
- name: GVISOR_BIN_DIR
  value: {{ .Values.gvisor.binDir | quote }}
- name: GVISOR_CONTAINERD_CONFIG
  value: {{ .Values.gvisor.containerd.config | quote }}
- name: GVISOR_CONTAINERD_DROPIN_DIR
  value: {{ .Values.gvisor.containerd.dropInDir | quote }}
- name: GVISOR_CRIO_DROPIN_DIR
  value: {{ .Values.gvisor.crio.dropInDir | quote }}
- name: GVISOR_NODE_LABEL
  value: {{ .Values.nodeLabel | quote }}
{{- end }}

{{- define "gvisor-installer.runscFlags" -}}
{{- $flags := list }}
{{- range $k, $v := .Values.gvisor.runscFlags }}
{{- $flags = append $flags (printf "%s=%v" $k $v) }}
{{- end }}
{{- join " " $flags }}
{{- end }}

{{/* A privileged container with the host's root at /host. */}}
{{- define "gvisor-installer.hostContainer" -}}
image: {{ include "gvisor-installer.image" .root }}
imagePullPolicy: {{ .root.Values.image.pullPolicy }}
args: [{{ .command | quote }}]
env:
{{- include "gvisor-installer.env" .root | nindent 2 }}
securityContext:
  privileged: true
volumeMounts:
  - name: host
    mountPath: /host
{{- end }}
