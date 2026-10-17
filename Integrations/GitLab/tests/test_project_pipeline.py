"""Check the configuration of this project's own pipeline."""

from pathlib import Path
import re
import unittest


PIPELINE = Path(__file__).resolve().parents[1] / ".gitlab-ci.yml"
# 컴포넌트 잡은 macOS 러너에서 돈다. GitLab 호스팅 macOS의 image는 컨테이너가 아니라 VM 이미지 이름이라
# digest로 고정할 수 없다. README는 이 잡에 image를 지정하라고 안내한다.
MACOS_JOBS = {"cartograph-corpus"}
# 최상위 키가 시작하는 줄에서 나눈다. 열 0의 주석은 앞 블록에 남는다.
TOP_LEVEL = re.compile(r"^(?=[^\s#])", re.MULTILINE)
# image: 줄에서 이미지 참조만 뽑는다. 태그와 날짜를 적은 줄 끝 주석은 허용한다.
IMAGE_LINE = re.compile(r"^[ \t]+image:[ \t]*(\S+)[ \t]*(?:#.*)?$", re.MULTILINE)
# GitLab 문서가 지원하는 digest 형식은 <image-name>@<digest>다. 태그와 달리 digest는 옮겨지지 않는다.
PINNED_IMAGE = re.compile(r"[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}")


def unpinned_images(text):
    """macOS 잡을 뺀 잡에서 digest로 고정되지 않은 image를 (잡, 값)으로 돌려준다.

    러너 이미지에 PyYAML이 없어 최상위 키 단위로 나눈다. 한 줄로 해석할 수 없는 image 항목(매핑 형식 등)도
    고정 여부를 확인할 수 없으므로 함께 돌려준다.
    """
    found = []
    for block in filter(str.strip, TOP_LEVEL.split(text)):
        job = block.split(":", 1)[0]
        if job in MACOS_JOBS:
            continue
        images = IMAGE_LINE.findall(block)
        if len(images) != len(re.findall(r"\bimage\s*:", block)):
            found.append((job, "unparsed image entry"))
        found += [(job, image) for image in images if not PINNED_IMAGE.fullmatch(image)]
    return found


class ProjectPipelineTests(unittest.TestCase):
    def test_every_linux_job_image_is_pinned_by_digest(self):
        # 검증 잡은 릴리스를 막는 관문이고, 릴리스 잡은 CI_JOB_TOKEN으로 Catalog 릴리스를 만든다.
        text = PIPELINE.read_text()
        self.assertTrue(IMAGE_LINE.findall(text))
        self.assertEqual(unpinned_images(text), [])

    def test_check_allows_hosted_macos_images_and_catches_new_linux_tags(self):
        text = PIPELINE.read_text()
        self.assertEqual(unpinned_images(text + "\ncartograph-corpus:\n  image: macos-15-xcode-16\n"), [])
        self.assertEqual(unpinned_images(text + "\nlint:\n  image: python:3.12-slim\n"),
                         [("lint", "python:3.12-slim")])
        self.assertEqual(unpinned_images(text + "\nlint:\n  image:\n    name: python:3.12-slim\n"),
                         [("lint", "unparsed image entry")])


if __name__ == "__main__":
    unittest.main()
