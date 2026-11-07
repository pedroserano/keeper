# Converts the EfficientNetV2-S orientation model from github.com/duartebarbosadev/deep-image-orientation-detection
# (MIT, see Resources/OrientationNet-LICENSE.txt; weights: release v2, orientation_model_v2_0.9882.pth) to the
# Core ML package Keeper bundles. Needs torch, torchvision and coremltools (Python 3.12):
#
#   python convert-orientation-net.py orientation_model_v2_0.9882.pth Resources/OrientationNet.mlpackage
#
# Its training rotates with PIL's ROTATE_90 (counter-clockwise), so class k means the photo needs k quarter
# turns clockwise, which is the label order Keeper reads.
import sys, torch, torch.nn as nn, torchvision.models as models, coremltools as ct
pth, out = sys.argv[1], sys.argv[2]
m = models.efficientnet_v2_s(weights=None)
m.classifier = nn.Sequential(nn.Dropout(p=0.3), nn.Linear(m.classifier[1].in_features, 4))
sd = torch.load(pth, map_location="cpu", weights_only=False)
if isinstance(sd, dict) and "model_state_dict" in sd: sd = sd["model_state_dict"]
if isinstance(sd, dict) and "state_dict" in sd: sd = sd["state_dict"]
sd = {k.replace("module.", "").replace("_orig_mod.", ""): v for k, v in sd.items()}
print(m.load_state_dict(sd))
m.eval()
class Wrap(nn.Module):
    """416x416 RGB 0-255 in (as Vision squashes it), centre 384 crop, ImageNet normalisation, softmax out."""
    def __init__(s, m):
        super().__init__(); s.m = m
        s.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1) * 255)
        s.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1) * 255)
    def forward(s, x):
        x = x[:, :, 16:400, 16:400]
        return torch.softmax(s.m((x - s.mean) / s.std), dim=1)
w = Wrap(m).eval()
traced = torch.jit.trace(w, torch.rand(1, 3, 416, 416) * 255)
ml = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=(1, 3, 416, 416), color_layout=ct.colorlayout.RGB)],
                classifier_config=ct.ClassifierConfig(["0", "90", "180", "270"]),
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
ml.short_description = "EfficientNetV2-S photo orientation (duartebarbosadev/deep-image-orientation-detection, MIT). Label = quarter turns clockwise needed."
ml.save(out)
print("saved", out)
