# ComfyUI Worker with S3/R2 Model Loading
# This script runs inside the RunPod worker to download models from R2 on cold start

import os
import boto3
import sys

# R2 Config from env
R2_ENDPOINT = os.getenv("R2_ENDPOINT", "https://38d27e0247b1a8b9aeb73d8ec4648262.r2.cloudflarestorage.com")
R2_ACCESS_KEY = os.getenv("R2_ACCESS_KEY_ID")
R2_SECRET_KEY = os.getenv("R2_SECRET_ACCESS_KEY")
R2_BUCKET = os.getenv("R2_BUCKET", "comfyui-models")

# Model paths in R2 -> local ComfyUI paths
MODEL_MAPPINGS = {
    # UNET/Diffusion models
    "unet/flux-2-klein-9b.safetensors": "models/diffusion_models/flux-2-klein-9b.safetensors",
    
    # VAE
    "vae/flux2-vae.safetensors": "models/vae/flux2-vae.safetensors",
    
    # Text Encoders / CLIP
    "text_encoders/qwen_3_8b_fp8mixed.safetensors": "models/text_encoders/qwen_3_8b_fp8mixed.safetensors",
    
    # LoRAs
    "loras/bfs_head_v1_flux-klein-9b_step3750_rank64.safetensors": "models/loras/bfs_head_v1_flux-klein-9b_step3750_rank64.safetensors",
}

def download_models():
    """Download required models from R2 to local ComfyUI paths"""
    if not R2_ACCESS_KEY or not R2_SECRET_KEY:
        print("R2 credentials not set, skipping model download")
        return
    
    s3 = boto3.client('s3',
        endpoint_url=R2_ENDPOINT,
        aws_access_key_id=R2_ACCESS_KEY,
        aws_secret_access_key=R2_SECRET_KEY,
        region_name='auto'
    )
    
    for r2_key, local_path in MODEL_MAPPINGS.items():
        full_path = f"/comfyui/{local_path}"
        
        if os.path.exists(full_path):
            print(f"✓ {local_path} already exists")
            continue
        
        print(f"📥 Downloading {r2_key} -> {local_path}...")
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        
        try:
            s3.download_file(R2_BUCKET, r2_key, full_path)
            size_mb = os.path.getsize(full_path) / 1024 / 1024
            print(f"  ✅ Done ({size_mb:.0f} MB)")
        except Exception as e:
            print(f"  ❌ Error: {e}", file=sys.stderr)
            raise

if __name__ == "__main__":
    download_models()
    print("Model download complete")
