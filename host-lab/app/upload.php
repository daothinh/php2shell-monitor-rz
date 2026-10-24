<?php
// upload.php — endpoint tải file "cũ" của khách hàng.
// ĐIỂM YẾU (cố ý cho lab): chỉ chặn rỗng, KHÔNG kiểm tra đuôi file
// -> kẻ tấn công upload .php trực tiếp (giai đoạn T3 của php2shell).
session_start();
header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'POST only']);
    exit;
}
if (empty($_FILES['file'])) {
    http_response_code(400);
    error_log('[upload.php] POST ma khong co file (co the la tan cong upload-progress): '
        . json_encode(array_keys($_POST)));
    echo json_encode(['error' => 'no file']);
    exit;
}

$f = $_FILES['file'];
$name = basename($f['name']);           // YẾU: nhận mọi đuôi file
$dest = __DIR__ . '/' . $name;
if (!move_uploaded_file($f['tmp_name'], $dest)) {
    http_response_code(500);
    echo json_encode(['error' => 'move failed']);
    exit;
}
error_log('[upload.php] da luu file: ' . $name);
echo json_encode(['ok' => true, 'saved_as' => $name]);
