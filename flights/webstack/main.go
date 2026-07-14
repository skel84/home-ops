package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/utils/ptr"
)

type WebStack struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata"`
	Spec              WebStackSpec   `json:"spec"`
	Status            WebStackStatus `json:"status,omitempty"`
}

type WebStackSpec struct {
	Image     string            `json:"image"`
	Replicas  *int32            `json:"replicas,omitempty"`
	AppPort   *int32            `json:"appPort,omitempty"`
	Password  string            `json:"password"`
	Env       []corev1.EnvVar   `json:"env,omitempty"`
	Postgres  PostgresSpec      `json:"postgres,omitempty"`
	Backup    *BackupSpec       `json:"backup,omitempty"`
	Ingress   *IngressSpec      `json:"ingress,omitempty"`
	Resources *ResourceSpec     `json:"resources,omitempty"`
}

type PostgresSpec struct {
	Instances *int32      `json:"instances,omitempty"`
	Storage   string      `json:"storage,omitempty"`
	Pooler    *PoolerSpec `json:"pooler,omitempty"`
}

type PoolerSpec struct {
	Instances *int32 `json:"instances,omitempty"`
}

type BackupSpec struct {
	Schedule       string `json:"schedule,omitempty"`
	RetentionDays  *int   `json:"retentionDays,omitempty"`
	Endpoint       string `json:"endpoint"`
	Bucket         string `json:"bucket"`
	AccessKeyID    string `json:"accessKeyId"`
	SecretAccessKey string `json:"secretAccessKey"`
}

type IngressSpec struct {
	Host        string            `json:"host,omitempty"`
	ClassName   string            `json:"className,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

type ResourceSpec struct {
	Requests *ResourceRequirements `json:"requests,omitempty"`
	Limits   *ResourceRequirements `json:"limits,omitempty"`
}

type ResourceRequirements struct {
	CPU    string `json:"cpu,omitempty"`
	Memory string `json:"memory,omitempty"`
}

type WebStackStatus struct {
	AppNamespace string `json:"appNamespace,omitempty"`
	DbNamespace  string `json:"dbNamespace,omitempty"`
	Ready        string `json:"ready,omitempty"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var stack WebStack
	if err := yaml.NewYAMLToJSONDecoder(os.Stdin).Decode(&stack); err != nil && err != io.EOF {
		return fmt.Errorf("decoding webstack: %w", err)
	}

	targetNs := stack.Namespace
	if targetNs == "" {
		targetNs = "default"
	}
	sel := map[string]string{"app.kubernetes.io/name": stack.Name}
	labels := map[string]string{
		"app.kubernetes.io/name":       stack.Name,
		"app.kubernetes.io/managed-by": "yokecd",
		"app.kubernetes.io/part-of":    "webstack",
	}

	spec := stack.Spec
	replicas := ptr.Deref(spec.Replicas, 1)
	appPort := ptr.Deref(spec.AppPort, 8080)
	pgInstances := ptr.Deref(spec.Postgres.Instances, 1)

	var resources []any

	resources = append(resources, &stack)

	resources = append(resources,
		quota(targetNs, stack.Name))

	for _, np := range netpols(targetNs, stack.Name, spec.Ingress != nil) {
		resources = append(resources, np)
	}

	bootSecretName := stack.Name + "-bootstrap"
	resources = append(resources, bootSecret(targetNs, stack.Name, spec.Password))

	var clusterObj any
	if spec.Backup != nil {
		resources = append(resources, bmanSecret(targetNs, stack.Name, spec.Backup))
		clusterObj = pgCluster(targetNs, stack.Name, spec.Postgres.Storage, pgInstances, bootSecretName, spec.Backup)
	} else {
		clusterObj = pgCluster(targetNs, stack.Name, spec.Postgres.Storage, pgInstances, bootSecretName, nil)
	}
	resources = append(resources, clusterObj)

	if spec.Backup != nil {
		resources = append(resources, schedBackup(targetNs, stack.Name, spec.Backup))
	}

	var poolerInstances int32 = 1
	if spec.Postgres.Pooler != nil && spec.Postgres.Pooler.Instances != nil {
		poolerInstances = *spec.Postgres.Pooler.Instances
	}
	if poolerInstances > 0 {
		resources = append(resources, pgPooler(targetNs, stack.Name, poolerInstances))
	}

	resources = append(resources, connSecret(targetNs, stack.Name, spec.Password))

	resources = append(resources, sa(targetNs, stack.Name))
	resources = append(resources, deploy(targetNs, stack.Name, spec.Image, replicas, appPort, spec.Env, spec.Resources, sel, labels))
	resources = append(resources, svc(targetNs, stack.Name, appPort))

	if spec.Ingress != nil {
		resources = append(resources, ing(targetNs, stack.Name, spec.Ingress))
	}

	stack.Status = WebStackStatus{
		AppNamespace: targetNs,
		DbNamespace:  targetNs,
		Ready:        "deployed",
	}

	return json.NewEncoder(os.Stdout).Encode(resources)
}

func quota(ns, name string) any {
	return &corev1.ResourceQuota{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "ResourceQuota"},
		ObjectMeta: metav1.ObjectMeta{Name: name + "-quota", Namespace: ns},
		Spec: corev1.ResourceQuotaSpec{Hard: corev1.ResourceList{
			corev1.ResourceRequestsCPU:    resource.MustParse("2"),
			corev1.ResourceRequestsMemory: resource.MustParse("4Gi"),
			corev1.ResourceLimitsCPU:      resource.MustParse("4"),
			corev1.ResourceLimitsMemory:   resource.MustParse("8Gi"),
			corev1.ResourcePersistentVolumeClaims: resource.MustParse("10"),
		}},
	}
}

func netpols(ns, name string, withIngress bool) []any {
	p := []any{
		&networkingv1.NetworkPolicy{
			TypeMeta:   metav1.TypeMeta{APIVersion: "networking.k8s.io/v1", Kind: "NetworkPolicy"},
			ObjectMeta: metav1.ObjectMeta{Name: name + "-default-deny", Namespace: ns},
			Spec: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
				Ingress:     []networkingv1.NetworkPolicyIngressRule{},
			},
		},
		&networkingv1.NetworkPolicy{
			TypeMeta:   metav1.TypeMeta{APIVersion: "networking.k8s.io/v1", Kind: "NetworkPolicy"},
			ObjectMeta: metav1.ObjectMeta{Name: name + "-allow-dns", Namespace: ns},
			Spec: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeEgress},
				Egress: []networkingv1.NetworkPolicyEgressRule{
					{Ports: []networkingv1.NetworkPolicyPort{{Port: ptr.To(intstr.FromInt32(53)), Protocol: ptr.To(corev1.ProtocolUDP)}}},
					{Ports: []networkingv1.NetworkPolicyPort{{Port: ptr.To(intstr.FromInt32(53)), Protocol: ptr.To(corev1.ProtocolTCP)}}},
				},
			},
		},
	}
	if withIngress {
		p = append(p, &networkingv1.NetworkPolicy{
			TypeMeta:   metav1.TypeMeta{APIVersion: "networking.k8s.io/v1", Kind: "NetworkPolicy"},
			ObjectMeta: metav1.ObjectMeta{Name: name + "-allow-ingress", Namespace: ns},
			Spec: networkingv1.NetworkPolicySpec{
				PodSelector: metav1.LabelSelector{},
				PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
				Ingress: []networkingv1.NetworkPolicyIngressRule{
					{From: []networkingv1.NetworkPolicyPeer{
						{PodSelector: &metav1.LabelSelector{MatchLabels: map[string]string{"app.kubernetes.io/name": "ingress-nginx"}}},
					}},
				},
			},
		})
	}
	return p
}

func bootSecret(ns, name, password string) any {
	return &corev1.Secret{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "Secret"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name + "-bootstrap",
			Namespace: ns,
			Labels:    map[string]string{"cnpg.io/reload": "true"},
		},
		Type:       corev1.SecretTypeBasicAuth,
		StringData: map[string]string{"username": "app", "password": password},
	}
}

func pgCluster(ns, name, storage string, instances int32, bootstrapSecretName string, backup *BackupSpec) any {
	storageSize := storage
	if storageSize == "" {
		storageSize = "10Gi"
	}
	spec := map[string]any{
		"instances":             instances,
		"primaryUpdateStrategy": "unsupervised",
		"imageName":             "ghcr.io/cloudnative-pg/postgresql:16",
		"bootstrap": map[string]any{
			"initdb": map[string]any{
				"database": "appdb",
				"owner":    "app",
				"secret":   map[string]any{"name": bootstrapSecretName},
			},
		},
		"storage": map[string]any{
			"size":         storageSize,
			"storageClass": "longhorn",
		},
		"managed": map[string]any{
			"roles": []any{
				map[string]any{"name": "app", "login": true, "superuser": false},
			},
		},
		"postgresql": map[string]any{
			"parameters": map[string]any{
				"max_connections": "200",
				"shared_buffers":  "256MB",
				"work_mem":        "16MB",
			},
		},
		"resources": map[string]any{
			"requests": map[string]any{"cpu": "250m", "memory": "512Mi"},
			"limits":   map[string]any{"cpu": "1", "memory": "1Gi"},
		},
	}
	if backup != nil {
		retention := "30d"
		if backup.RetentionDays != nil && *backup.RetentionDays > 0 {
			retention = fmt.Sprintf("%dd", *backup.RetentionDays)
		}
		spec["backup"] = map[string]any{
			"retentionPolicy": retention,
			"barmanObjectStore": map[string]any{
				"endpointURL": backup.Endpoint,
				"destinationPath": "s3://" + backup.Bucket + "/backups/" + name,
				"serverName":  name,
				"tags":        map[string]any{"app.kubernetes.io/name": name},
				"data":        map[string]any{"compression": "gzip"},
				"historyTags": map[string]any{"app.kubernetes.io/name": name},
				"s3Credentials": map[string]any{
					"accessKeyId":     map[string]any{"name": name + "-barman", "key": "ACCESS_KEY_ID"},
					"secretAccessKey": map[string]any{"name": name + "-barman", "key": "SECRET_ACCESS_KEY"},
				},
				"wal":         map[string]any{"compression": "gzip", "maxParallel": 8},
			},
		}
	}
	return &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": "postgresql.cnpg.io/v1",
			"kind":       "Cluster",
			"metadata":   map[string]any{"name": name, "namespace": ns},
			"spec":       spec,
		},
	}
}

func pgPooler(ns, name string, instances int32) any {
	return &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": "postgresql.cnpg.io/v1",
			"kind":       "Pooler",
			"metadata":   map[string]any{"name": name + "-pooler", "namespace": ns},
			"spec": map[string]any{
				"cluster":   map[string]any{"name": name},
				"instances": instances,
				"type":      "rw",
				"pgbouncer": map[string]any{
					"poolMode": "transaction",
					"parameters": map[string]any{
						"max_client_conn": "1000",
						"default_pool_size": "20",
					},
				},
			},
		},
	}
}

func bmanSecret(ns, name string, backup *BackupSpec) any {
	return &corev1.Secret{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "Secret"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name + "-barman",
			Namespace: ns,
			Labels:    map[string]string{"cnpg.io/reload": "true"},
		},
		StringData: map[string]string{
			"ACCESS_KEY_ID":     backup.AccessKeyID,
			"SECRET_ACCESS_KEY": backup.SecretAccessKey,
		},
	}
}

func schedBackup(ns, name string, backup *BackupSpec) any {
	schedule := backup.Schedule
	if schedule == "" {
		schedule = "0 2 * * *"
	}
	return &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": "postgresql.cnpg.io/v1",
			"kind":       "ScheduledBackup",
			"metadata":   map[string]any{"name": name + "-backup", "namespace": ns},
			"spec": map[string]any{
				"schedule":             schedule,
				"backupOwnerReference": "cluster",
				"cluster":              map[string]any{"name": name},
				"method":               "barmanObjectStore",
			},
		},
	}
}

func connSecret(ns, name, password string) any {
	return &corev1.Secret{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "Secret"},
		ObjectMeta: metav1.ObjectMeta{Name: name + "-pg-conn", Namespace: ns},
		StringData: map[string]string{
			"DATABASE_USER":     "app",
			"DATABASE_NAME":     "appdb",
			"DATABASE_HOST":     name + "-rw." + ns + ".svc.cluster.local",
			"DATABASE_PASSWORD": password,
		},
	}
}

func sa(ns, name string) any {
	return &corev1.ServiceAccount{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "ServiceAccount"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		AutomountServiceAccountToken: ptr.To(false),
	}
}

func deploy(ns, name, image string, replicas, appPort int32, env []corev1.EnvVar, res *ResourceSpec, sel, labels map[string]string) any {
	resources := corev1.ResourceRequirements{
		Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m"), corev1.ResourceMemory: resource.MustParse("256Mi")},
		Limits:   corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m"), corev1.ResourceMemory: resource.MustParse("256Mi")},
	}
	if res != nil {
		overrideResource(&resources.Requests, res.Requests)
		overrideResource(&resources.Limits, res.Limits)
	}

	envVars := []corev1.EnvVar{
		{Name: "APP_NAME", Value: name},
		{Name: "APP_PORT", Value: strconv.Itoa(int(appPort))},
	}
	for i, e := range env {
		envVars = append(envVars, env[i])
		_ = e
	}

	return &appsv1.Deployment{
		TypeMeta:   metav1.TypeMeta{APIVersion: "apps/v1", Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Labels: labels},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: sel},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					ServiceAccountName:            name,
					AutomountServiceAccountToken: ptr.To(false),
					SecurityContext: &corev1.PodSecurityContext{
						RunAsNonRoot: ptr.To(true),
						RunAsUser:    ptr.To[int64](1001),
						FSGroup:      ptr.To[int64](1001),
					},
					Containers: []corev1.Container{
						{
							Name:    name,
							Image:   image,
							Ports:   []corev1.ContainerPort{{Name: "http", ContainerPort: appPort}},
							Env:     envVars,
							Resources: resources,
							EnvFrom: []corev1.EnvFromSource{
								{SecretRef: &corev1.SecretEnvSource{LocalObjectReference: corev1.LocalObjectReference{Name: name + "-pg-conn"}}},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler:          corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromInt32(appPort)}},
								InitialDelaySeconds: 5,
								PeriodSeconds:       10,
							},
							LivenessProbe: &corev1.Probe{
								ProbeHandler:          corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromInt32(appPort)}},
								InitialDelaySeconds: 15,
								PeriodSeconds:       20,
							},
						},
					},
				},
			},
		},
	}
}

func overrideResource(dst *corev1.ResourceList, src *ResourceRequirements) {
	if src == nil {
		return
	}
	if src.CPU != "" {
		(*dst)[corev1.ResourceCPU] = resource.MustParse(src.CPU)
	}
	if src.Memory != "" {
		(*dst)[corev1.ResourceMemory] = resource.MustParse(src.Memory)
	}
}

func svc(ns, name string, port int32) any {
	return &corev1.Service{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "Service"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app.kubernetes.io/name": name},
			Ports:    []corev1.ServicePort{{Name: "http", Port: 80, TargetPort: intstr.FromInt32(port)}},
		},
	}
}

func ing(ns, name string, ingSpec *IngressSpec) any {
	className := ingSpec.ClassName
	if className == "" {
		className = "nginx"
	}
	annotations := ingSpec.Annotations
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations["external-dns.alpha.kubernetes.io/target"] = "external.rbl.lol"

	return &networkingv1.Ingress{
		TypeMeta:   metav1.TypeMeta{APIVersion: "networking.k8s.io/v1", Kind: "Ingress"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Annotations: annotations},
		Spec: networkingv1.IngressSpec{
			IngressClassName: ptr.To(className),
			Rules: []networkingv1.IngressRule{
				{
					Host: ingSpec.Host,
					IngressRuleValue: networkingv1.IngressRuleValue{
						HTTP: &networkingv1.HTTPIngressRuleValue{
							Paths: []networkingv1.HTTPIngressPath{
								{Path: "/", PathType: ptr.To(networkingv1.PathTypePrefix), Backend: networkingv1.IngressBackend{Service: &networkingv1.IngressServiceBackend{Name: name, Port: networkingv1.ServiceBackendPort{Number: 80}}}},
							},
						},
					},
				},
			},
		},
	}
}
