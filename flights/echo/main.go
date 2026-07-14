package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	release := releaseName()
	namespace := namespace()

	resources := []any{
		deployment(release, namespace),
		service(release, namespace),
	}

	return json.NewEncoder(os.Stdout).Encode(resources)
}

func releaseName() string {
	if r := os.Getenv("YOKE_RELEASE"); r != "" {
		return r
	}
	return "echo"
}

func namespace() string {
	if n := os.Getenv("YOKE_NAMESPACE"); n != "" {
		return n
	}
	if n := os.Getenv("NAMESPACE"); n != "" {
		return n
	}
	return "default"
}

func deployment(release, namespace string) map[string]any {
	return map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name":      release,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"replicas": 1,
			"selector": map[string]any{
				"matchLabels": map[string]any{"app": release},
			},
			"template": map[string]any{
				"metadata": map[string]any{
					"labels": map[string]any{"app": release},
				},
				"spec": map[string]any{
					"containers": []any{
						map[string]any{
							"name":  release,
							"image": "ealen/echo-server:latest",
							"env": []any{
								map[string]any{"name": "PORT", "value": "8080"},
							},
							"ports": []any{
								map[string]any{"containerPort": 8080},
							},
						},
					},
				},
			},
		},
	}
}

func service(release, namespace string) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Service",
		"metadata": map[string]any{
			"name":      release,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"selector": map[string]any{"app": release},
			"ports": []any{
				map[string]any{
					"port":       80,
					"targetPort": 8080,
				},
			},
		},
	}
}
