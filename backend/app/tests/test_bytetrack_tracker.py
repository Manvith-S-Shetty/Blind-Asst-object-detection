import pytest
from app.pipeline.real.bytetrack_tracker import ByteTrackTracker
from app.models.schemas import Detection, BoundingBox


@pytest.mark.asyncio
async def test_stable_track_ids_across_frames():
    tracker = ByteTrackTracker(track_high_thresh=0.4, match_thresh=0.7)

    # Frame 1: Person at (100, 100, 200, 300)
    frame1 = [
        Detection(label="person", confidence=0.9, bbox=BoundingBox(x1=100, y1=100, x2=200, y2=300)),
        Detection(label="chair", confidence=0.85, bbox=BoundingBox(x1=400, y1=400, x2=480, y2=480)),
    ]
    res1 = await tracker.update(frame1)
    assert len(res1) == 2
    id_person = res1[0].track_id
    id_chair = res1[1].track_id
    assert id_person is not None
    assert id_chair is not None
    assert id_person != id_chair

    # Frame 2: Person moves slightly right (110, 100, 210, 300), chair remains
    frame2 = [
        Detection(label="person", confidence=0.88, bbox=BoundingBox(x1=110, y1=100, x2=210, y2=300)),
        Detection(label="chair", confidence=0.84, bbox=BoundingBox(x1=400, y1=400, x2=480, y2=480)),
    ]
    res2 = await tracker.update(frame2)
    assert res2[0].track_id == id_person
    assert res2[1].track_id == id_chair


@pytest.mark.asyncio
async def test_missed_detection_and_reappearance():
    tracker = ByteTrackTracker(track_high_thresh=0.4, match_thresh=0.7, max_time_lost=10)

    # Frame 1: Object present
    f1 = [Detection(label="bicycle", confidence=0.85, bbox=BoundingBox(x1=50, y1=50, x2=150, y2=150))]
    res1 = await tracker.update(f1)
    bike_id = res1[0].track_id
    assert bike_id is not None

    # Frame 2: Missed detection (occlusion) -> returns empty, does NOT fabricate stale location
    f2 = []
    res2 = await tracker.update(f2)
    assert res2 == []

    # Frame 3: Object reappears in nearby area
    f3 = [Detection(label="bicycle", confidence=0.82, bbox=BoundingBox(x1=55, y1=52, x2=155, y2=152))]
    res3 = await tracker.update(f3)
    assert len(res3) == 1
    # Track re-identified
    assert res3[0].track_id == bike_id


@pytest.mark.asyncio
async def test_permanent_loss_culls_track():
    tracker = ByteTrackTracker(track_high_thresh=0.4, match_thresh=0.7, max_time_lost=2)

    # Frame 1: Object present
    f1 = [Detection(label="dog", confidence=0.9, bbox=BoundingBox(x1=10, y1=10, x2=60, y2=60))]
    res1 = await tracker.update(f1)
    dog_id = res1[0].track_id

    # Disappears for 3 frames (> max_time_lost)
    for _ in range(3):
        await tracker.update([])

    # Lost tracks culled
    assert len(tracker.lost_tracks) == 0

    # New object appears later
    f_new = [Detection(label="dog", confidence=0.88, bbox=BoundingBox(x1=10, y1=10, x2=60, y2=60))]
    res_new = await tracker.update(f_new)
    assert res_new[0].track_id != dog_id


@pytest.mark.asyncio
async def test_tracker_reset():
    tracker = ByteTrackTracker()
    f1 = [Detection(label="car", confidence=0.95, bbox=BoundingBox(x1=20, y1=20, x2=100, y2=100))]
    res1 = await tracker.update(f1)
    assert res1[0].track_id == 1

    tracker.reset()
    assert len(tracker.tracked_tracks) == 0
    assert len(tracker.lost_tracks) == 0
    assert tracker.frame_id == 0

    res_after_reset = await tracker.update(f1)
    assert res_after_reset[0].track_id == 1
