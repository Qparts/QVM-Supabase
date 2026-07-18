-- Synced from QVM/test branch applied migration history (version 20260218125823, name: copy_order_number_sequences_from_main_to_test)
TRUNCATE TABLE qvm_new_apps.order_number_sequences RESTART IDENTITY;

INSERT INTO qvm_new_apps.order_number_sequences
(sequence_id, created_at, lists_data_id, region_id, sequence_name, prefix)
OVERRIDING SYSTEM VALUE
VALUES
(1,'2025-06-16 08:02:28.73014+00',1,11,'petromin_west_seq','JPR'),
(2,'2025-06-16 08:02:28.73014+00',1,12,'petromin_east_seq','ERR'),
(3,'2025-06-16 08:02:28.73014+00',1,13,'petromin_riyadh_seq','B'),
(4,'2025-06-16 08:02:28.73014+00',2,11,'petromin_body_paint_seq','BPN'),
(5,'2025-06-16 08:02:28.73014+00',2,12,'petromin_body_paint_seq','BPN'),
(6,'2025-06-16 08:02:28.73014+00',2,13,'petromin_body_paint_seq','BPN'),
(7,'2025-06-16 08:02:28.73014+00',3,12,'almajdouie_east_seq','ERM'),
(8,'2025-06-16 08:02:28.73014+00',3,13,'almajdouie_riyadh_seq','RPM'),
(9,'2025-06-16 08:02:28.73014+00',5,13,'jeri_services_seq','RJ'),
(10,'2025-06-16 08:02:28.73014+00',6,11,'motor_lube_seq','JM'),
(11,'2025-06-16 08:02:28.73014+00',7,14,'tawuniya_seq','TA'),
(12,'2025-06-16 08:02:28.73014+00',176,13,'tawuniya_seq','TA'),
(13,'2025-06-16 08:02:28.73014+00',177,11,'tawuniya_seq','TA'),
(14,'2025-06-16 08:02:28.73014+00',178,12,'tawuniya_seq','TA');

SELECT setval(
  'qvm_new_apps.order_number_sequences_sequence_id_seq',
  (SELECT COALESCE(MAX(sequence_id), 0) FROM qvm_new_apps.order_number_sequences)
);;
